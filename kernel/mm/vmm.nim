# ============================================================================
# kernel/mm/vmm.nim -- x86-64 4-level paging (no PSE512, no huge pages).
#
# Address-space layout we install (and which Limine's HHDM already matches):
#   0x0000_0000..0x7FFF_FFFF_FFFF_FFFF : unused (user half; reserved for later)
#   KERNEL_VBASE .. +kernel size        : kernel text/rodata/rwdata/bss, NX off
#                                          only for data sections
#   hhdmOffset .. +physTop              : direct map of ALL physical RAM, RW,
#                                          NX set (we never exec from the map)
#
# Why identity-map nothing? Limine entered long mode with its own tables that
# map both the kernel and the whole RAM at HHDM. We rebuild equivalent tables
# so we control flags (NX/W^X), then atomically swap CR3. The boot stack is
# inside our kernel image, so it stays mapped across the switch.
#
# Nim bare-metal trick: page-table walk helpers take `ptr PageTableEntry`
# (== uint64) and index with `[idx]` on UncheckedArray views -- pure pointer
# math, zero allocation, works before AND after the PMM exists (the early
# allocator hook below lets us bootstrap without recursion).
# ============================================================================

{.push hints: off, raises: [].}

import ../types, ../limine, ../mem, pmm
import ../arch/x86_64/io {.all.}   # writeCr3 / invlpg / mfence / rdmsr

const
  PTE_PRESENT*: uint64 = 1 shl 0
  PTE_WRITE*:   uint64 = 1 shl 1
  PTE_USER*:    uint64 = 1 shl 2
  PTE_PWT*:     uint64 = 1 shl 3
  PTE_PCD*:     uint64 = 1 shl 4
  PTE_ACCESSED*:uint64 = 1 shl 5
  PTE_DIRTY*:   uint64 = 1 shl 6
  PTE_HUGE*:    uint64 = 1 shl 7
  PTE_GLOBAL*:  uint64 = 1 shl 8
  PTE_NX*:      uint64 = (1'u64 shl 63)
  ADDR_MASK*:   uint64 = 0x0000FFFFFFFFFFFF'u64   # low 48 bits (parenthesized so `not` binds correctly)
  PAGE_FLAGS_RW_NX* = PTE_PRESENT or PTE_WRITE or PTE_NX
  PAGE_FLAGS_RO*    = PTE_PRESENT
  PAGE_FLAGS_EXEC*  = PTE_PRESENT or PTE_WRITE   # writable+exec for simplicity

type
  PageTable* = array[512, PageTableEntry]
  KernelAsm* = object     # exported symbols from the linker script
    nothing*: int         # placeholder; real access via externs below

# Linker-provided section boundaries (see linker/kernel.ld -- symbols are
# emitted as char arrays, address-of gives the boundary).
var ktextStart* {.importc: "__ktext_start", nodecl.}: uint8
var ktextEnd* {.importc: "__ktext_end", nodecl.}: uint8
var krodataStart* {.importc: "__krodata_start", nodecl.}: uint8
var krodataEnd* {.importc: "__krodata_end", nodecl.}: uint8
var krwdataStart* {.importc: "__krwdata_start", nodecl.}: uint8
var krwdataEnd* {.importc: "__krwdata_end", nodecl.}: uint8
var kbssStart* {.importc: "__kbss_start", nodecl.}: uint8
var kbssEnd* {.importc: "__kbss_end", nodecl.}: uint8

var pml4Phys*: PhysAddr       # physical base of the kernel PML4
var pml4Virt*: VirtAddr       # same, through HHDM
var hhdm*: uint64             # cached HHDM offset (must match limine's!)
var nxSupported* = false

template idx(va: untyped, level: int): int =
  # Nim array/UncheckedArray indexing demands `int`; extract the 9-bit
  # table index for `level` (3 = PML4, 2 = PDPT, 1 = PD, 0 = PT) and
  # widen it to int in one place. `va: untyped` so VirtAddr (= uint64
  # alias) arguments bind without ordinal-type complaints.
  int((va shr (12 + 9 * level)) and 511)
proc nextLevelTable(cur: ptr UncheckedArray[PageTableEntry], slot: int):
    ptr UncheckedArray[PageTableEntry] =
  ## Return child table for `slot`, allocating a zeroed frame if absent.
  if (cur[slot] and PTE_PRESENT) != 0:
    let pa = cur[slot] and ADDR_MASK
    return cast[ptr UncheckedArray[PageTableEntry]](pa + hhdm)
  let f = allocFrameZeroed()
  if f == 0: return nil
  cur[slot] = f or PTE_PRESENT or PTE_WRITE
  return cast[ptr UncheckedArray[PageTableEntry]](f + hhdm)

proc mapPage*(va: VirtAddr, pa: PhysAddr, flags: uint64) =
  var tbl = cast[ptr UncheckedArray[PageTableEntry]](pml4Virt)
  var entryPa = pml4Phys
  var lvl = 3
  while lvl >= 1:
    let i = idx(va, lvl)
    # descend
    tbl = nextLevelTable(tbl, i)
    if tbl.isNil: return
    dec lvl
  # lvl == 0 now: leaf
  let i0 = idx(va, 0)
  tbl[i0] = (pa and ADDR_MASK) or flags

proc unmapPage*(va: VirtAddr) =
  var tbl = cast[ptr UncheckedArray[PageTableEntry]](pml4Virt)
  var lvl = 3
  while lvl >= 0:
    let i = idx(va, lvl)
    if (tbl[i] and PTE_PRESENT) == 0: return
    if lvl == 0:
      tbl[i] = 0
      invlpg(va)
      return
    tbl = cast[ptr UncheckedArray[PageTableEntry]]((tbl[i] and ADDR_MASK) + hhdm)
    dec lvl

proc virtIsMapped*(va: VirtAddr): bool =
  var tbl = cast[ptr UncheckedArray[PageTableEntry]](pml4Virt)
  var lvl = 3
  while lvl >= 0:
    let i = idx(va, lvl)
    if (tbl[i] and PTE_PRESENT) == 0: return false
    if lvl == 0: return true
    tbl = cast[ptr UncheckedArray[PageTableEntry]]((tbl[i] and ADDR_MASK) + hhdm)
    dec lvl
  false

proc initVmm*() =
  ## Build fresh kernel tables and load them into CR3. Safe to call exactly
  ## once, right after initPmm().
  hhdm = hhdmOffset()
  # EFER (MSR 0xC000_0088) bit 11 == NXE. If the CPU supports Execute-Disable
  # we flip it on; otherwise every PTE_NX we set would fault.
  let efer = rdmsr(0xC0000088'u32)
  nxSupported = (efer and (1'u64 shl 11)) != 0 or (rdmsr(0x80000001'u32) and (1'u64 shl 20)) != 0
  if nxSupported:
    wrmsr(0xC0000088'u32, efer or (1'u64 shl 11))   # enable NXE

  pml4Phys = allocFrameZeroed()
  if pml4Phys == 0: return
  pml4Virt = pml4Phys + hhdm

  # ---- 1. kernel image itself ----------------------------------------------
  let kBase = alignDown(KERNEL_VBASE, PAGE_SIZE)
  let kTop  = alignUp(cast[VirtAddr](addr kbssEnd), PAGE_SIZE)
  var va = kBase
  # .text: RX ; .rodata: R+NX ; .data/.bss: RW+NX
  while va < kTop:
    let pa = va - KERNEL_VBASE   # our ld script places phys = virt - VBASE
    var fl = PTE_PRESENT or PTE_WRITE
    if nxSupported: fl = fl or PTE_NX
    if va >= alignDown(cast[VirtAddr](addr ktextStart), PAGE_SIZE) and
       va < alignUp(cast[VirtAddr](addr ktextEnd), PAGE_SIZE):
      fl = PTE_PRESENT or PTE_WRITE               # executable text (no NX)
    elif va >= cast[VirtAddr](addr krodataStart) and
         va < cast[VirtAddr](addr krodataEnd):
      fl = PTE_PRESENT                            # read-only data
      if nxSupported: fl = fl or PTE_NX
    mapPage(va, pa, fl)
    va += PAGE_SIZE

  # ---- 2. full physical RAM direct-mapped at hhdm ---------------------------
  let n = memmapCount()
  var i = 0
  var topPa: uint64 = 0
  while i < n:
    let e = memmapEntry(i)
    if e.base + e.length > topPa: topPa = e.base + e.length
    inc i
  var pv: uint64 = 0
  let physTop = alignUp(topPa, PAGE_SIZE)
  let dmFlags =
    if nxSupported: PAGE_FLAGS_RW_NX
    else: PTE_PRESENT or PTE_WRITE
  while pv < physTop:
    mapPage(hhdm + pv, pv, dmFlags)
    pv += PAGE_SIZE

  # ---- 3. MMIO hole guard: re-map VGA framebuffer WB is fine; leave as-is.

  # ---- 4. flip CR3. From here OUR tables are law. ---------------------------
  writeCr3(pml4Phys)
  mfence()

proc kernelPml4Phys*(): PhysAddr = pml4Phys

{.pop.}
