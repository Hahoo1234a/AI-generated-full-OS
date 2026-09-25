# ============================================================================
# kernel/posix/ramfs.nim -- mounts the Limine-provided module(s) as files.
#
# The build system (`make disk`) produces a small "NIMFS" image:
#   header: magic 'N''I''M''F' | u32 version | u32 entryCount
#   entries: name[64] | u32 offset | u32 size   (all offsets from image base)
#   payload follows, each file page-aligned-ish (we don't care, it's copied).
#
# If no NIMFS module is present we fall back to exposing every raw Limine
# module as /rd/<name> verbatim -- so `limine.cfg` with MODULE_PATH lines
# alone already gives you a usable /rd tree.
#
# POSIX note: writes to ramfs files grow them via kmalloc; read(2) past EOF
# returns 0 bytes (== EOF) exactly like Linux tmpfs.
# ============================================================================

{.push hints: off, raises: [].}

import ../types, ../limine, ../mem, ../mm/kmalloc, vfs

const
  NIMFS_MAGIC*: uint32 = 0x464D494E  # "NIMF" little-endian
  NIMFS_VERSION*: uint32 = 1
  MAX_ENTRIES* = 64

type
  NimFsHeader {.bycopy, pure.} = object
    magic*: uint32
    version*: uint32
    entryCount*: uint32
    reserved*: uint32

  NimFsEntry {.bycopy, pure.} = object
    name*: array[NAME_MAX, char]
    offset*: uint32
    size*: uint32
    flags*: uint32

proc addFileToDir(dirIno: int, name: string, src: ptr UncheckedArray[uint8],
                  size: uint64): Errno =
  let ni = createNodePublic(dirIno, name, nkFile, fsRam)
  if ni < 0: return -EEXIST
  let n = getNode(ni)
  if size > 0:
    let buf = kmalloc(size)
    if buf.isNil: return -ENOMEM
    copyMem(buf, src, size.int)
    n.data = cast[ptr UncheckedArray[uint8]](buf)
    n.cap = size
  n.size = size
  0'i32

proc mountNimFs(imgBase: uint64, imgSize: uint64): Errno =
  let hdr = cast[ptr NimFsHeader](imgBase)
  if hdr.magic != NIMFS_MAGIC or hdr.version != NIMFS_VERSION:
    return -EINVAL
  if hdr.entryCount > MAX_ENTRIES: return -EFBIG
  let ent = cast[ptr UncheckedArray[NimFsEntry]](imgBase + sizeof(NimFsHeader).uint64)
  var i = 0
  while i < hdr.entryCount.int:
    let e = ent[i]
    let dataPtr = cast[ptr UncheckedArray[uint8]](imgBase + e.offset.uint64)
    # bounds-check the entry against the image before copying anything out
    if e.offset.uint64 + e.size.uint64 > imgSize: return -EIO
    discard addFileToDir(rootIno, getName(e.name), dataPtr, e.size.uint64)
    inc i
  0'i32

proc mountRawModules(): Errno =
  ## Fallback: expose each Limine module at /rd/<string>.
  let rd = vfsMkdir("/", "rd")
  if rd < 0: return -EIO
  var i = 0
  while i < modulesCount():
    let m = moduleAt(i)
    let nm = if m.string != nil and m.string.len > 0: $m.string else: "mod" & $i
    let src = cast[ptr UncheckedArray[uint8]](physToVirt(m.address))
    discard addFileToDir(rd, nm, src, m.size)
    inc i
  0'i32

proc initRamfs*() =
  ## Called after initVfs(); attaches boot modules to the tree.
  var mounted = false
  var i = 0
  while i < modulesCount():
    let m = moduleAt(i)
    let base = physToVirt(m.address)
    let p = cast[ptr uint32](base)
    if p[] == NIMFS_MAGIC:
      discard mountNimFs(base, m.size)
      mounted = true
    inc i
  if not mounted:
    discard mountRawModules()

{.pop.}
