# ============================================================================
# kernel/mem.nim -- tiny low-level memory primitives used by every subsystem.
#
# Because we compile with --gc:none and --mm:none, Nim's own `alloc`/`new`
# are unavailable (and would drag in the runtime allocator). Everything is
# hand-rolled over raw addresses:
#   * zeroMem/fillMem/copyMem : thin wrappers around compiler intrinsics that
#     Nim emits as plain C loops / rep stosq when targeting standalone.
#   * readOnce/writeOnce      : volatile-style access so the optimizer can't
#     hoist MMIO reads/writes out of polling loops.
# ============================================================================

{.push hints: off.}

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

# Volatile MMIO helpers: `asm volatile` with a "memory" clobber prevents
# GCC from reordering device accesses across these barriers.
template readOnce*[T](p: ptr T): T =
  var v: T
  asm volatile("movq {{%1}}, {{%0}}" : "=r"(v) : "r"(p))
  v

template writeOnce*[T](p: ptr T, val: T) =
  asm volatile("movq {{%1}}, {{%0}}" : : "r"(p), "r"(val) : "memory")

{.pop.}
