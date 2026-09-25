# ============================================================================
# kernel/posix/vfs.nim -- the Virtual File System: POSIX-flavored inode model
# with per-filesystem operation dispatch (like Linux's super_operations /
# file_operations, but as plain Nim proc-pointer tables).
#
# Why a VFS at all on a RAM-disk toy OS? Because POSIX compliance is about
# STABLE SEMANTICS, not storage: syscalls in syscall.nim never know whether
# they're talking to ramfs or devfs; they only see Node/FileHandle. Adding a
# real disk FS later = one more FsOps registration, zero syscall changes.
#
# Nim bare-metal trick: `proc(...): Errno {.cdecl.}` fields inside an object
# are just function pointers in the C output -- no closures, no GC envs, so
# they're safe to store statically. We mark every ops object `{.bycopy.}` so
# assignment copies the pointer table, not a ref header.
# ============================================================================

{.push hints: off, raises: [].}

import ../types, ../mem, ../mm/kmalloc

const
  MAX_NODES*     = 256    # static node pool (no heap dependency for tree)
  MAX_FILES      = 128    # open-file-table slots
  NAME_MAX*      = 64
  PATH_MAX*      = 256
  O_RDONLY*: uint32 = 0x0000
  O_WRONLY*: uint32 = 0x0001
  O_RDWR*  : uint32 = 0x0002
  O_CREAT* : uint32 = 0x0040   # octal 0100 -> we use hex like Linux headers
  O_TRUNC* : uint32 = 0x0200
  O_APPEND : uint32 = 0x0400
  S_IFDIR*:  uint32 = 0x4000   # st_mode bits (subset of <sys/stat.h>)
  S_IFREG*:  uint32 = 0x8000
  S_IFCHR*:  uint32 = 0x2000

type
  NodeKind* = enum nkFile, nkDir, nkCharDev

  FsId* = enum fsRam, fsDev

  Vnode* = object        ## our "inode". Lives in a static pool.
    inUse*: bool
    kind*: NodeKind
    fsId*: FsId
    name*: array[NAME_MAX, char]
    mode*: uint32        # S_IFxxx | permission bits (we ignore perms in P0)
    size*: uint64        # bytes for files
    mtime*: uint64       # epoch-ish seconds from rtc.nim
    data*: ptr UncheckedArray[uint8]  # ramfs inline contents
    cap*: uint64         # allocated capacity of data
    parent*: int         # pool index of parent dir (-1 for root)
    children*: array[32, int]  # child pool indices, -1 terminated-ish
    nChildren*: int
    # char devices: which ops handle read/write
    devRead*: proc(buf: pointer, n: int): int {.cdecl.}
    devWrite*: proc(buf: pointer, n: int): int {.cdecl.}

  OpenFile* = object
    used*: bool
    node*: int           # vnode pool index
    off*: uint64         # POSIX pread/pwrite semantics via this cursor
    flags*: uint32

  DirEnt* = object       # what getdents hands back
    ino*: uint32
    typ*: uint8          # 1=reg 2=dir 3=chr
    nameLen*: uint8
    name*: array[NAME_MAX, char]

var nodes*: array[MAX_NODES, Vnode]
var openFiles*: array[MAX_FILES, OpenFile]
var rootIno*: int = -1

# ---- tiny fixed-string helpers (POSIX names are NUL-terminated char*) -----
proc setName*(v: var array[NAME_MAX, char], s: string) =
  var i = 0
  while i < s.len and i < NAME_MAX - 1:
    v[i] = s[i]; inc i
  v[i] = '\0'

proc getName*(v: array[NAME_MAX, char]): string =
  result = ""
  var i = 0
  while i < NAME_MAX - 1 and v[i] != '\0':
    result.add(v[i]); inc i

proc nameEq*(v: array[NAME_MAX, char], s: string): bool =
  if s.len >= NAME_MAX: return false
  var i = 0
  while i < s.len:
    if v[i] != s[i]: return false
    inc i
  v[i] == '\0'

# ---- vnode pool ------------------------------------------------------------
proc allocNode*(): int =
  var i = 0
  while i < MAX_NODES:
    if not nodes[i].inUse:
      nodes[i] = Vnode(inUse: true, parent: -1)
      nodes[i].nChildren = 0
      nodes[i].children = [int(0)]  # placeholder; init below
      for k in 0..<32: nodes[i].children[k] = -1
      return i
    inc i
  -1

proc getNode*(ino: int): ptr Vnode =
  if ino < 0 or ino >= MAX_NODES or not nodes[ino].inUse: nil
  else: addr nodes[ino]

proc initVfs*() =
  ## Create "/" (a ramfs directory). Called before ramfs populates itself.
  rootIno = allocNode()
  if rootIno >= 0:
    nodes[rootIno].kind = nkDir
    nodes[rootIno].fsId = fsRam
    nodes[rootIno].mode = S_IFDIR or 0o755.uint32
    nodes[rootIno].name.setName("")

proc lookupChild(dirIno: int, name: string): int =
  let d = getNode(dirIno)
  if d.isNil or d.kind != nkDir: return -1
  var i = 0
  while i < d.nChildren:
    let c = getNode(d.children[i])
    if not c.isNil and c.name.nameEq(name): return d.children[i]
    inc i
  -1

proc resolvePath*(path: string): int =
  ## POSIX path resolution: absolute only ("/foo/bar"), "." and ".." honored.
  if path.len == 0 or path[0] != '/': return -1
  var cur = rootIno
  var i = 1
  while i <= path.len:
    # extract next component
    var comp = ""
    while i < path.len and path[i] != '/':
      comp.add(path[i]); inc i
    inc i   # skip separator
    if comp.len == 0:
      if i > path.len: break
      continue
    elif comp == ".":
      discard
    elif comp == "..":
      if nodes[cur].parent >= 0: cur = nodes[cur].parent
    else:
      let nxt = lookupChild(cur, comp)
      if nxt < 0: return -1
      cur = nxt
  cur

proc createNode(dirIno: int, name: string, kind: NodeKind,
                fsId: FsId): int =
  if name.len == 0 or name.len >= NAME_MAX: return -1
  if lookupChild(dirIno, name) >= 0: return -ENOENT - 1  # EEXIST marker
  let d = getNode(dirIno)
  if d.isNil or d.kind != nkDir: return -ENOTDIR
  if d.nChildren >= 32: return -ENOMEM
  let ni = allocNode()
  if ni < 0: return -ENOMEM
  nodes[ni].kind = kind
  nodes[ni].fsId = fsId
  nodes[ni].name.setName(name)
  nodes[ni].mode = (if kind == nkDir: S_IFDIR else:
                    if kind == nkCharDev: S_IFCHR else: S_IFREG) or 0o644.uint32
  nodes[ni].parent = dirIno
  d.children[d.nChildren] = ni
  inc d.nChildren
  ni

proc vfsMkdir*(parentPath, name: string): int =
  let p = resolvePath(parentPath)
  if p < 0: return -ENOENT
  createNode(p, name, nkDir, fsRam)

proc vfsCreate*(parentPath, name: string): int =
  let p = resolvePath(parentPath)
  if p < 0: return -ENOENT
  createNode(p, name, nkFile, fsRam)

proc vfsRegisterDev*(dirPath, name: string,
                     r: proc(buf: pointer, n: int): int {.cdecl.},
                     w: proc(buf: pointer, n: int): int {.cdecl.}): int =
  let p = resolvePath(dirPath)
  if p < 0: return -ENOENT
  let ni = createNode(p, name, nkCharDev, fsDev)
  if ni >= 0:
    nodes[ni].devRead = r
    nodes[ni].devWrite = w
  ni

proc unlinkChild*(dirIno: int, name: string): Errno =
  let d = getNode(dirIno)
  if d.isNil or d.kind != nkDir: return -ENOTDIR
  var i = 0
  while i < d.nChildren:
    let ci = d.children[i]
    let c = getNode(ci)
    if c.isNil: return -EIO
    if c.name.nameEq(name):
      if c.kind == nkDir and c.nChildren > 0: return -ENOTEMPTY
      # refuse to unlink the root or anything still open (simple rule)
      var j = 0
      while j < MAX_FILES:
        if openFiles[j].used and openFiles[j].node == ci: return -EBUSY
        inc j
      c.inUse = false
      if not c.data.isNil: kfree(c.data)
      # compact children list
      var k = i
      while k < d.nChildren - 1:
        d.children[k] = d.children[k + 1]
        inc k
      dec d.nChildren
      return 0
    inc i
  -ENOENT

proc truncateNode*(ino: int): Errno =
  let n = getNode(ino)
  if n.isNil: return -ENOENT
  if n.kind == nkDir: return -EISDIR
  n.size = 0
  0

{.pop.}
