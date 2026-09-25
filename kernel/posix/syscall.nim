# ============================================================================
# kernel/posix/syscall.nim -- the syscall dispatch layer (POSIX semantics).
#
# Nim bare-metal trick #4: there is NO ring-3 userland yet, so "syscalls" are
# plain proc calls from the shell. BUT we keep the exact Linux x86-64 ABI
# numbers and return conventions (negative -errno on failure) so that when we
# add SYSCALL/SYSRET + a real IDT later, ONLY the entry stub changes; every
# implementation below is already written to be callable from an asm trampoline.
#
# fd table: 0=stdin(tty) 1=stdout(tty) 2=stderr(tty), then open() allocates
# upward. read/write dispatch through the vnode kind: ramfs files hit their
# data blob, char devices hit devRead/devWrite, tty fds hit ttyRead/ttyWrite.
# ============================================================================

{.push hints: off, raises: [].}

import ../types, ../mem, ../mm/kmalloc, vfs
import tty, ../drivers/vga, ../drivers/serial

const
  MAX_FILES*     = 64    ## per-"process" fd table size (0..2 reserved stdio)

  SYS_READ*      = 0
  SYS_WRITE*     = 1
  SYS_OPEN*      = 2
  SYS_CLOSE*     = 3
  SYS_LSEEK*     = 8
  SYS_UNLINK*    = 10
  SYS_GETDENTS*  = 78
  SYS_KILLNODE*  = 999   # debug-only helper number

var cwdIno*: int = -1     # "/" once VFS init'd

proc setRoot*(ino: int) = cwdIno = ino

template isOpenFd(fd: cint): bool =
  fd >= 0 and fd < MAX_FILES and openFiles[fd].used

proc rfindSep(s: string): int =
  var i = s.len - 1
  while i >= 0:
    if s[i] == '/': return i
    dec i
  -1

proc sysOpen*(path: cstring, flags: uint32, mode: uint32): Errno {.cdecl.} =
  let p = $path
  var dirPath = "/"
  var name = p
  var ino = resolvePath(p)
  if ino >= 0:
    # exists: fail if O_CREAT|O_EXCL style exclusive requested
    if (flags and 0x0040'u32) != 0 and (flags and 0x0080'u32) != 0:
      return -EEXIST
  else:
    # find parent component for create
    let slash = rfindSep(p)
    if slash < 0 or (flags and 0x0040'u32) == 0: return -ENOENT
    dirPath = substr(p, 0, slash - 1)
    name = substr(p, slash + 1)
    let dino = resolvePath(if dirPath.len == 0: "/" else: dirPath)
    if dino < 0: return -ENOENT
    ino = createNodePublic(dino, name, nkFile, fsRam)
    if ino < 0: return -ENOMEM
  # allocate an fd slot
  var i = 3
  while i < MAX_FILES:
    if not openFiles[i].used:
      openFiles[i].used = true
      openFiles[i].node = ino
      openFiles[i].off = 0
      openFiles[i].flags = flags
      if (flags and 0x0200'u32) != 0:  # O_TRUNC
        discard truncateNode(ino)
      return i.Errno
    inc i
  -EMFILE

proc sysClose*(fd: cint): Errno {.cdecl.} =
  if not isOpenFd(fd): return -EBADF
  openFiles[fd].used = false
  0'i32

proc sysRead*(fd: cint, buf: pointer, count: csize): Ssize {.cdecl.} =
  if not isOpenFd(fd): return -(EBADF.Ssize)
  let n = getNode(openFiles[fd].node)
  if n.isNil: return -EIO.Ssize
  case n.kind
  of nkCharDev:
    if n.devRead.isNil: return -ENXIO.Ssize
    n.devRead(buf, count.int).Ssize
  of nkDir:
    # POSIX: read() on a directory -> EISDIR (use getdents instead)
    -EISDIR.Ssize
  of nkFile:
    if openFiles[fd].off >= n.size: return 0   # EOF
    let avail = (n.size - openFiles[fd].off).int
    let take = min(count.int, avail)
    copyMem(buf, cast[pointer](cast[uint64](n.data) + openFiles[fd].off), take)
    openFiles[fd].off += take.uint64
    take.Ssize

proc sysWrite*(fd: cint, buf: pointer, count: csize): Ssize {.cdecl.} =
  if not isOpenFd(fd): return -EBADF.Ssize
  let n = getNode(openFiles[fd].node)
  if n.isNil: return -EIO.Ssize
  case n.kind
  of nkCharDev:
    if n.devWrite.isNil: return -ENXIO.Ssize
    n.devWrite(buf, count.int).Ssize
  of nkDir: -EISDIR.Ssize
  of nkFile:
    let need = openFiles[fd].off + count.uint64
    if need > n.cap:
      let newCap = alignUp(max(need * 2, 4096'u64), PAGE_SIZE)
      let grown = kmalloc(newCap)
      if grown.isNil: return -ENOMEM.Ssize
      if not n.data.isNil:
        copyMem(grown, n.data, n.size.int)
        kfree(n.data)
      n.data = cast[ptr UncheckedArray[uint8]](grown)
      n.cap = newCap
    copyMem(cast[pointer](cast[uint64](n.data) + openFiles[fd].off), buf, count.int)
    openFiles[fd].off += count.uint64
    if openFiles[fd].off > n.size: n.size = openFiles[fd].off
    count.Ssize

proc sysLseek*(fd: cint, off: int64, whence: cint): int64 {.cdecl.} =
  if not isOpenFd(fd): return (-EBADF).int64
  let n = getNode(openFiles[fd].node)
  if n.isNil: return (-EIO).int64
  var base: int64
  case whence
  of 0: base = 0                      # SEEK_SET
  of 1: base = openFiles[fd].off.int64 # SEEK_CUR
  of 2: base = n.size.int64            # SEEK_END
  else: return (-EINVAL).int64
  let res = base + off
  if res < 0: return (-EINVAL).int64
  openFiles[fd].off = res.uint64
  res

proc sysGetdents*(fd: cint, dirp: pointer, count: csize): Ssize {.cdecl.} =
  ## Simplified linux_dirent64 stream: fixed-size records for predictability.
  if not isOpenFd(fd): return -EBADF.Ssize
  let n = getNode(openFiles[fd].node)
  if n.isNil: return -EIO.Ssize
  if n.kind != nkDir: return -ENOTDIR.Ssize
  let recSize = sizeof(DirEnt).csize
  if count < recSize: return -EINVAL.Ssize
  let idx = openFiles[fd].off.int
  if idx >= n.nChildren: return 0     # end of stream
  let child = getNode(n.children[idx])
  if child.isNil: return -EIO.Ssize
  var de = DirEnt(ino: idx.uint32 + 1,
                  typ: (if child.kind == nkDir: 2'u8 else:
                        if child.kind == nkCharDev: 3'u8 else: 1'u8))
  de.name.setName(getName(child.name))
  de.nameLen = getName(child.name).len.uint8
  copyMem(dirp, addr de, sizeof(DirEnt).int)
  openFiles[fd].off += 1
  recSize.Ssize

proc sysUnlink*(path: cstring): Errno {.cdecl.} =
  let p = $path
  let slash = rfindSep(p)
  if slash < 0: return -EINVAL
  let dirPath = substr(p, 0, slash - 1)
  let name = substr(p, slash + 1)
  let dino = resolvePath(if dirPath.len == 0: "/" else: dirPath)
  if dino < 0: return -ENOENT
  unlinkChild(dino, name)

proc sysMkdir*(path: cstring, mode: uint32): Errno {.cdecl.} =
  let p = $path
  let slash = rfindSep(p)
  if slash < 0: return -EINVAL
  let dirPath = substr(p, 0, slash - 1)
  let name = substr(p, slash + 1)
  let dino = resolvePath(if dirPath.len == 0: "/" else: dirPath)
  if dino < 0: return -ENOENT
  let ni = createNodePublic(dino, name, nkDir, fsRam)
  if ni < 0: return -EEXIST
  0'i32

proc sysStat*(path: cstring, st: ptr Stat): Errno {.cdecl.} =
  let ino = resolvePath($path)
  if ino < 0: return -ENOENT
  let n = getNode(ino)
  st.st_ino = ino.uint64
  st.st_mode = n.mode
  st.st_size = n.size
  st.st_nlink = (if n.kind == nkDir: 2'u64 + n.nChildren.uint64 else: 1'u64)
  st.st_blksize = PAGE_SIZE
  st.st_blocks = (n.size + 511) div 512
  0'i32

# ---- umbrella dispatcher mirroring the future SYSCALL ABI -------------------
proc syscalls*(nr: cint, a0, a1, a2: uint64): int64 {.cdecl.} =
  case nr
  of SYS_READ:   sysRead(a0.cint, cast[pointer](a1), a2.csize).int64
  of SYS_WRITE:  sysWrite(a0.cint, cast[pointer](a1), a2.csize).int64
  of SYS_OPEN:   sysOpen(cast[cstring](a0), a1.uint32, a2.uint32).int64
  of SYS_CLOSE:  sysClose(a0.cint).int64
  of SYS_LSEEK:  sysLseek(a0.cint, a1.int64, a2.cint)
  of SYS_GETDENTS: sysGetdents(a0.cint, cast[pointer](a1), a2.csize).int64
  of SYS_UNLINK: sysUnlink(cast[cstring](a0)).int64
  else:          (-ENOSYS).int64

# stdio helpers used by shell.nim (printf-like but allocation-free) ----------
# Echo every kernel message to BOTH consoles: VGA text buffer for the QEMU
# window, 16550 UART for `qemu -serial mon:stdio` hosts. putcSerial/writeSerial
# come from ../drivers/serial (imported at the top of this file).
proc kprint*(s: string) =
  writeVga(s)
  var i = 0
  while i < s.len:
    putcSerial(s[i]); inc i

{.pop.}
