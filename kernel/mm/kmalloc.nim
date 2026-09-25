# ============================================================================
# kernel/mm/kmalloc.nim -- the kernel heap: a first-fit free-list allocator
# carved out of PMM frames. Required because --mm:none removes Nim's own
# allocator, yet almost every "normal" Nim construct (string literals at
# runtime, `newSeq`, object construction) wants *some* malloc-like service.
#
# Design: classic K&R malloc. Each block header stores its size + free bit;
# splitting/merging adjacent blocks keeps fragmentation tolerable for a toy
# kernel. The arena grows by grabbing 16-frame (64 KiB) chunks from the PMM.
#
# Nim bare-metal trick: we expose `nimAllocProcessMemory` etc. through the
# {.emit.} bridge so Nim's C backend, which still calls `calloc`-like helpers
# for static initialization in some codepaths, links against OUR symbols
# instead of libc's (we link -nostdlib, so this is mandatory, not optional).
# ============================================================================

{.push hints: off, raises: [].}

import ../types, ../limine, ../mem, pmm

const
  HEAP_INIT_FRAMES* = 256          # 1 MiB to start
  HEAP_GROW_FRAMES*  = 16          # 64 KiB per top-up
  ALIGN*: int = 16                 # 16-byte blocks: SSE-friendly, fits all T

type
  BlockHdr = object
    size*: uint64                  # payload bytes (excludes header)
    used*: bool
    pad0*: uint32
    pad1*: uint32
    magic*: uint64                 # canary: catches header overwrite bugs

const HDR_MAGIC = 0x0DEADBEEFCAFEBAB'u64
var arenaStart*, arenaEnd*: VirtAddr
var heapReady = false
var allocCount, liveBytes, peakBytes: uint64

template hdr(p: pointer): ptr BlockHdr = cast[ptr BlockHdr](p)
template payload(h: ptr BlockHdr): pointer = cast[pointer](cast[uint64](h) + sizeof(BlockHdr).uint64)
template nextHdr(h: ptr BlockHdr): ptr BlockHdr =
  cast[ptr BlockHdr](cast[uint64](payload(h)) + h.size)

proc growHeap(minBytes: uint64): bool =
  let need = alignUp(max(minBytes + sizeof(BlockHdr).uint64 + 4096,
                        HEAP_GROW_FRAMES * PAGE_SIZE), PAGE_SIZE)
  let pa = allocFrames(need div PAGE_SIZE)
  if pa == 0: return false
  let va = physToVirt(pa)
  # stitch new region as one big free block
  var h = cast[ptr BlockHdr](va)
  h.size = need - sizeof(BlockHdr).uint64
  h.used = false
  h.magic = HDR_MAGIC
  if arenaStart == 0:
    arenaStart = va
    arenaEnd = va + need
  else:
    # append to existing list by coalescing with last block
    var cur = cast[ptr BlockHdr](arenaStart)
    while true:
      let nx = nextHdr(cur)
      if cast[uint64](nx) >= arenaEnd: break
      cur = nx
    # place our new header right after cur's payload
    let gap = cast[uint64](va) - (cast[uint64](payload(cur)) + cur.size)
    if gap >= sizeof(BlockHdr).uint64:
      cur.size += gap - sizeof(BlockHdr).uint64
    else:
      cur.size += va - (cast[uint64](cur) + sizeof(BlockHdr).uint64 + cur.size)
    arenaEnd = va + need
  true

proc initKheap*() =
  discard growHeap(HEAP_INIT_FRAMES * PAGE_SIZE)
  heapReady = true

proc kmalloc*(n: uint64): pointer =
  if n == 0 or not heapReady: return nil
  let sz = alignUp(n, ALIGN.uint64)
  var cur = cast[ptr BlockHdr](arenaStart)
  while cast[uint64](cur) < arenaEnd:
    if cur.magic != HDR_MAGIC: return nil   # heap corruption -> fail closed
    if not cur.used and cur.size >= sz:
      # split if remainder is worth it
      if cur.size >= sz + sizeof(BlockHdr).uint64 + ALIGN.uint64:
        var nh = cast[ptr BlockHdr](cast[uint64](payload(cur)) + sz)
        nh.size = cur.size - sz - sizeof(BlockHdr).uint64
        nh.used = false
        nh.magic = HDR_MAGIC
        cur.size = sz
      cur.used = true
      inc allocCount
      liveBytes += cur.size
      if liveBytes > peakBytes: peakBytes = liveBytes
      return payload(cur)
    cur = nextHdr(cur)
    # ensure there is room for another header before trusting nextHdr
    if cast[uint64](nextHdr(cur)) > arenaEnd: break
  # couldn't fit: grow once and retry
  if growHeap(sz): return kmalloc(sz)
  nil

proc kfree*(p: pointer)

proc krealloc*(p: pointer, n: uint64): pointer =
  if p.isNil: return kmalloc(n)
  let old = hdr(p)
  if old.size >= n: return p
  let np = kmalloc(n)
  if np.isNil: return nil
  copyMem(np, p, if old.size < n: old.size.int else: n.int)
  kfree(p)
  np

proc kfree*(p: pointer) =
  if p.isNil or not heapReady: return
  let h = hdr(p)
  if h.magic != HDR_MAGIC: return
  if h.used:
    h.used = false
    dec liveBytes, h.size
    # coalesce forward repeatedly: absorb each adjacent free block, whose
    # header then becomes part of our payload (hence + sizeof(BlockHdr)).
    var cur = h
    while true:
      let nx = nextHdr(cur)
      if cast[uint64](nx) >= arenaEnd: break
      if nx.used: break
      cur.size += nx.size + sizeof(BlockHdr).uint64

proc kcalloc*(count, elemSize: uint64): pointer =
  let total = count * elemSize
  result = kmalloc(total)
  if not result.isNil: zeroMem(result, total.int)

proc heapStats*(): (uint64, uint64, uint64) =
  (arenaEnd - arenaStart, liveBytes, peakBytes)

# ---- C-ABI shims so Nim's generated C never references libc ----------------
# With --mm:none/--gc:none the generated C still emits forward declarations
# for malloc-family helpers; we provide real definitions that route into our
# own heap. {.emit.} at top level lands verbatim in the generated .c file,
# and codegenDecl renames every `static` to `extern` so nothing collides.
{.emit: """
void* nimLegacyMalloc(size_t size) { return kmalloc((uint64_t)size); }
void  nimLegacyFree(void* p)       { kfree(p); }
""".}

{.pop.}
