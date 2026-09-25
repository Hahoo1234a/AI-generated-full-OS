# ============================================================================
# kernel/mm/pmm.nim -- Physical Memory Manager: a flat bitmap allocator over
# the Limine memory map, using the HHDM window to touch physical RAM.
#
# Strategy (classic, boring, correct):
#   1. Scan the memmap twice: first pass finds max physical address so we can
#      size the bitmap; second pass marks every frame FREE except reserved /
#      used / kernel regions.
#   2. The bitmap itself lives in physical frames we claim during init --
#      chicken-and-egg solved by carving it out of the *last* big free region
#      before publishing the free list.
#   3. allocFrame() scans for a clear bit with a rolling cursor (amortized
#      O(1) sequential allocation); freeFrame() clears + updates counters.
#
# Nim bare-metal trick: `ptr UncheckedArray[uint64]` gives us pointer
# arithmetic WITHOUT bounds checks (checks are globally off anyway, but the
# type documents intent). Bit ops use uint64 words: 1 bit per 4 KiB frame,
# so 1 MiB of bitmap covers 512 GiB of RAM.
# ============================================================================

{.push hints: off, raises: [].}

import ../types, ../limine, ../mem

const MAX_MEMMAP* = 4096    # sane upper bound on memmap entries

type
  PmmStats = object
    totalFrames*: uint64
    freeFrames*: uint64
    reservedFrames*: uint64

var bitmap*: ptr UncheckedArray[uint64]  ## 1 = allocated, 0 = free
var bitmapFrames*: uint64                ## frames consumed by the bitmap
var maxFrame*: uint64                    ## one past the last valid frame #
var cursor*: uint64                      ## rolling search index
var stats: PmmStats
var pmmReady = false

template bitSet(f: uint64) =
  bitmap[f shr 6] = bitmap[f shr 6] or (1'u64 shl (f and 63))
template bitClear(f: uint64) =
  bitmap[f shr 6] = bitmap[f shr 6] and not(1'u64 shl (f and 63))
template bitTest(f: uint64): bool =
  (bitmap[f shr 6] and (1'u64 shl (f and 63))) != 0

proc markRangeUsed(paBase, paEnd: uint64) =
  var f = paBase div PAGE_SIZE
  let fe = alignUp(paEnd, PAGE_SIZE) div PAGE_SIZE
  while f < fe and f < maxFrame:
    bitSet(f)
    inc f

proc markRangeFree(paBase, paEnd: uint64) =
  var f = alignUp(paBase, PAGE_SIZE) div PAGE_SIZE
  let fe = alignDown(paEnd, PAGE_SIZE) div PAGE_SIZE
  while f < fe and f < maxFrame:
    if f >= 32: bitClear(f)   # never free the low 128 KiB identity junk
    inc f

proc initPmm*() =
  ## Must run before anything else that allocates. Uses ONLY the Limine
  ## memmap via the HHDM; touches no heap.
  # --- pass 1: topology -----------------------------------------------------
  var topPa: uint64 = 0
  let n = memmapCount()
  var i = 0
  while i < n:
    let e = memmapEntry(i)
    if e.kind == MM_FREE_MEMORY or e.kind == MM_BOOTLOADER_RECLAIMABLE:
      let end_ = e.base + e.length
      if end_ > topPa: topPa = end_
    inc i
  maxFrame = topPa div PAGE_SIZE
  let wordsNeeded = int((maxFrame div 64) + 1)
  let bytesNeeded = alignUp(wordsNeeded * 8'u64, PAGE_SIZE)
  bitmapFrames = bytesNeeded div PAGE_SIZE

  # --- carve the bitmap out of the biggest free region ----------------------
  var bestBase: uint64 = 0
  var bestLen: uint64 = 0
  i = 0
  while i < n:
    let e = memmapEntry(i)
    if e.kind == MM_FREE_MEMORY and e.length > bestLen and e.base >= 0x100000'u64:
      bestLen = e.length
      bestBase = e.base
    inc i
  if bestLen < bytesNeeded + 16'u64*PAGE_SIZE:
    return  # hopeless; kernel_init will notice pmmReady == false and halt
  bitmap = cast[ptr UncheckedArray[uint64]](physToVirt(bestBase))
  # mark everything used, then selectively free (fail-safe default)
  var w = 0
  while w.int < wordsNeeded:
    bitmap[w.uint64] = not 0'u64
    inc w
  stats.totalFrames = maxFrame

  # --- pass 2: publish free ranges ------------------------------------------
  i = 0
  while i < n:
    let e = memmapEntry(i)
    case e.kind
    of MM_FREE_MEMORY, MM_BOOTLOADER_RECLAIMABLE, MM_ACPI_RECLAIMABLE:
      markRangeFree(e.base, e.base + e.length)
    else:
      markRangeUsed(e.base, e.base + e.length)
    inc i

  # reclaim our own structures + the bitmap itself + kernel image
  markRangeUsed(bestBase, bestBase + bytesNeeded)
  markRangeUsed(0x0'u64, 0x100000'u64)          # real-mode IVT/BDA/legacy
  # count what survived
  var freeCount: uint64 = 0
  var f: uint64 = 0
  while f < maxFrame:
    if not bitTest(f): inc freeCount
    inc f
  stats.freeFrames = freeCount
  stats.reservedFrames = maxFrame - freeCount
  cursor = 32'u64
  pmmReady = true

proc physTop*(): uint64 = maxFrame * PAGE_SIZE
proc freeFrameCount*(): uint64 = stats.freeFrames
proc totalFrameCount*(): uint64 = stats.totalFrames
proc pmmInitialized*(): bool = pmmReady

proc allocFrame*(): PhysAddr =
  ## Returns PHYSICAL address of a zero-filled? NO -- raw, caller must zero.
  ## Returns 0 on OOM (frame 0 is permanently reserved so 0 is unambiguous).
  if not pmmReady: return 0'u64
  var tries: uint64 = 0
  var f = cursor
  while tries < maxFrame:
    if not bitTest(f):
      bitSet(f)
      cursor = f + 1
      dec stats.freeFrames
      return f * PAGE_SIZE
    f += 1
    if f >= maxFrame: f = 32
    inc tries
  return 0'u64

proc allocFrameZeroed*(): PhysAddr =
  let pa = allocFrame()
  if pa != 0: zeroPage(physToVirt(pa))
  pa

proc allocFrames*(count: uint64): PhysAddr =
  ## Contiguous allocation (used for the RAM disk copy). Naive scan.
  if count == 0 or not pmmReady: return 0'u64
  var start: uint64 = 32
  var run: uint64 = 0
  var f: uint64 = 32
  while f < maxFrame:
    if not bitTest(f):
      if run == 0: start = f
      inc run
      if run == count:
        var g = start
        while g < start + count:
          bitSet(g); inc g
        stats.freeFrames -= count
        return start * PAGE_SIZE
    else:
      run = 0
    inc f
  return 0'u64

proc freeFrame*(pa: PhysAddr) =
  let f = pa div PAGE_SIZE
  if f < maxFrame and bitTest(f):
    bitClear(f)
    inc stats.freeFrames
    if f < cursor: cursor = f

{.pop.}
