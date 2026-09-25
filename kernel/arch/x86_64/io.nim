# ============================================================================
# kernel/arch/x86_64/io.nim -- legacy PIO + a few CPU instructions.
#
# Nim bare-metal trick #2: inline asm operands. Inside `asm`, every `%0`-style
# placeholder must be written with DOUBLED braces ({{%0}}) so the Nim template
# engine passes them through to GCC unchanged. Constraint letters are the
# standard x86 ones ("Nd" = immediate or %dx, "a"/"d" = eax/edx).
# ============================================================================

{.push hints: off.}

proc outb*(port: uint16, val: uint8) {.inline.} =
  asm volatile("outb {{%0}}, {{%1}}" : : "a"(val), "Nd"(port))

proc inb*(port: uint16): uint8 {.inline.} =
  asm volatile("inb {{%1}}, {{%0}}" : "=a"(result) : "Nd"(port))

proc outw*(port: uint16, val: uint16) {.inline.} =
  asm volatile("outw {{%0}}, {{%1}}" : : "a"(val), "Nd"(port))

proc inw*(port: uint16): uint16 {.inline.} =
  asm volatile("inw {{%1}}, {{%0}}" : "=a"(result) : "Nd"(port))

proc outl*(port: uint16, val: uint32) {.inline.} =
  asm volatile("outl {{%0}}, {{%1}}" : : "a"(val), "Nd"(port))

proc inl*(port: uint16): uint32 {.inline.} =
  asm volatile("inl {{%1}}, {{%0}}" : "=a"(result) : "Nd"(port))

## Wait one bus cycle -- used between two chained PIC/index-register writes.
proc ioWait*() {.inline.} =
  outb(0x80'u16, 0'u8)

proc cli*() {.inline.} =
  asm volatile("cli" : : : "memory")

proc sti*() {.inline.} =
  asm volatile("sti" : : : "memory")

proc hlt*() {.inline.} =
  asm volatile("hlt" : : : "memory")

## Pause hint -- spins without hammering the memory bus (used by sched/idle).
proc pause*() {.inline.} =
  asm volatile("pause" : : : "memory")

proc readCr0*(): uint64 {.inline.} =
  asm volatile("movq %%cr0, {{%0}}" : "=r"(result))

proc writeCr0*(v: uint64) {.inline.} =
  asm volatile("movq {{%0}}, %%cr0" : : "r"(v) : "memory")

proc readCr3*(): uint64 {.inline.} =
  asm volatile("movq %%cr3, {{%0}}" : "=r"(result))

proc writeCr3*(v: uint64) {.inline.} =
  asm volatile("movq {{%0}}, %%cr3" : : "r"(v) : "memory")

proc invlpg*(addr: uint64) {.inline.} =
  asm volatile("invlpg ({{%0}})" : : "r"(addr) : "memory")

proc mfence*() {.inline.} =
  asm volatile("mfence" : : : "memory")

proc rdmsr*(msr: uint32): uint64 {.inline.} =
  var lo, hi: uint32
  asm volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(msr))
  result = (uint64(hi) shl 32) or uint64(lo)

proc wrmsr*(msr: uint32, v: uint64) {.inline.} =
  let lo = uint32(v and 0xFFFFFFFF)
  let hi = uint32(v shr 32)
  asm volatile("wrmsr" : : "c"(msr), "a"(lo), "d"(hi) : "memory")

{.pop.}
