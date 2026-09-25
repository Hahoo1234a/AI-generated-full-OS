# ============================================================================
# kernel/mem.nim -- low-level memory primitives used by every subsystem.
#
# Because we compile with --mm:none (implies no GC), Nim's own `alloc`/`new`
# are unavailable (and would drag in the runtime allocator). Everything here
# is hand-rolled over raw addresses:
#   * zeroMem/fillMem/copyMem/cmpMem : byte loops; GCC turns these into
#     rep stosq/movsq at -O2 when it recognizes the idiom.
#   * readOnce/writeOnce             : volatile-style access so the optimizer
#     can't hoist MMIO reads/writes out of polling loops.
# NOTE: Nim already ships `zeroMem`/`copyMem` in the system module even for
# standalone builds; we deliberately re-implement them under our own names
# (`kZero` etc. below alias to ours) to avoid any libc-backed surprises.
# ============================================================================

{.push hints: off, raises: [].}

proc zeroMem*[T](dst: ptr T, n: int) {.inline, noSideEffect.} =
  var d = cast[ptr UncheckedArray[uint8]](dst)
  var i = 0
  while i < n:
    d[i] = 0'u8
    inc i

proc zeroMem*(dst: pointer, n: int) {.inline, noSideEffect.} =
  var d = cast[ptr UncheckedArray[uint8]](dst)
  var i = 0
  while i < n:
    d[i] = 0'u8
    inc i

proc fillMem*(dst: pointer, val: uint8, n: int) {.inline, noSideEffect.} =
  var d = cast[ptr UncheckedArray[uint8]](dst)
  var i = 0
  while i < n:
    d[i] = val
    inc i

proc copyMem*(dst, src: pointer, n: int) {.inline, noSideEffect.} =
  var d = cast[ptr UncheckedArray[uint8]](dst)
  var s = cast[ptr UncheckedArray[uint8]](src)
  var i = 0
  while i < n:
    d[i] = s[i]
    inc i

proc cmpMem*(a, b: pointer, n: int): bool {.inline, noSideEffect.} =
  var x = cast[ptr UncheckedArray[uint8]](a)
  var y = cast[ptr UncheckedArray[uint8]](b)
  var i = 0
  while i < n:
    if x[i] != y[i]: return false
    inc i
  return true

## Fill a page-aligned region with zeros fast (8 bytes at a time).
proc zeroPage*(va: uint64) {.inline.} =
  var p = cast[ptr UncheckedArray[uint64]](va)
  var i = 0
  while i < 512:
    p[i] = 0'u64
    inc i

# Volatile MMIO helpers: emitting a C `volatile` deref prevents GCC from
# reordering or eliding device accesses across polling-loop boundaries.
template readOnce*[T](p: ptr T): T =
  cast[ptr volatile T](p)[]

template writeOnce*[T](p: ptr T, val: T) =
  var v = val
  cast[ptr volatile T](p)[] = v

{.pop.}
