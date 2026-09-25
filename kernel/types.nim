# ============================================================================
# kernel/types.nim -- Fundamental type aliases used across the whole kernel.
#
# Bare-metal Nim trick #1: on a hosted target `int`/`pointer` map to libc
# types. On --os:standalone they are still 64-bit on x86_64, but we define
# explicit-width aliases so driver code never depends on the compiler's
# default integer width. Everything that touches hardware uses these.
# ============================================================================

type
  PhysAddr* = uint64   ## raw physical address (what the MMU/PMM speak)
  VirtAddr* = uint64   ## virtual address as seen by kernel code
  PAddr* = PhysAddr    ## short alias used by the PMM
  FrameNumber* = uint64 ## physical frame index: phys addr shr 12

  Pid* = int32         ## POSIX-style process id (we keep it signed: -1 == error)
  Fd* = int32          ## POSIX-style file descriptor (0,1,2 reserved)
  Errno* = int32       ## POSIX errno values returned through `-Result` style

  Ssize* = int            ## signed count type for read/write return values
                          ## (POSIX ssize_t); `isize` is NOT a Nim builtin.

  PageTableEntry* = uint64  ## one 8-byte x86-64 PTE
  Port* = uint16            ## legacy PIO port number

const
  PAGE_SIZE*: uint64 = 4096
  PAGE_SHIFT*: int = 12
  PAGE_MASK*: uint64 = not(PAGE_SIZE - 1)   # 0xFFFFFFFFFFFFF000

  KERNEL_VBASE*: uint64 = 0xFFFFFFFF80100000'u64  # must match ENTRY / .text origin in linker/kernel.ld

# Minimal set of errno constants we surface from the POSIX layer.
const
  EPERM*: Errno = 1      ## Operation not permitted
  ENOENT*: Errno = 2     ## No such file or directory
  EIO*: Errno = 5        ## I/O error
  EBADF*: Errno = 9      ## Bad file descriptor
  EAGAIN*: Errno = 11    ## Resource temporarily unavailable (non-blocking read)
  ENOMEM*: Errno = 12    ## Out of memory
  EACCES*: Errno = 13    ## Permission denied
  EBUSY*: Errno = 16     ## Device or resource busy
  EEXIST*: Errno = 17    ## File exists
  ENODEV*: Errno = 19    ## No such device
  ENOTDIR*: Errno = 20   ## Not a directory
  EISDIR*: Errno = 21    ## Is a directory
  EINVAL*: Errno = 22    ## Invalid argument
  EFBIG*: Errno = 27     ## File too large
  ENOSYS*: Errno = 38    ## Function not implemented
  EMFILE*: Errno = 24    ## Too many open files
  ENXIO*: Errno = 6      ## No such device or address
  EFAULT*: Errno = 14    ## Bad address
  ENOTEMPTY*: Errno = 39 ## Directory not empty

template alignUp*(x, a: uint64): uint64 = ((x + a - 1) and not (a - 1))
template alignDown*(x, a: uint64): uint64 = (x and not(a - 1))
template pageAlign*(x: uint64): uint64 = alignUp(x, PAGE_SIZE)
