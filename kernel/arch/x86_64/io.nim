# ============================================================================
# kernel/arch/x86_64/io.nim -- legacy PIO, CPU flags, control registers.
#
# Nim bare-metal trick #2 (IMPORTANT): do NOT use Nim's `asm` statement with
# GCC operand-constraint syntax (`asm volatile("..." : "=a"(x) : ...)`).
# Nim's parser chokes on the leading `:` after the string literal (it parses
# it as a section header -> "Invalid pragma expression"). This was verified
# empirically with Nim 1.6.x. The portable, battle-tested way to get inline
# assembly into Nim's C output is the {.emit.} + importc bridge:
#
#   proc name(args): T {.importc: "c_name", nodecl.}   # declare as "C func"
#   {.emit: ["/* actual asm here */"].}                # emit verbatim C+asm
#
# GCC statement-expressions (`({ ... })`) give us *return values* from asm.
# `"iK"` lets the assembler pick `al` (byte port) or `dx` (wide port) form;
# we always pass ports in DX via the `"d"` constraint for full 16-bit range.
# ============================================================================

{.push hints: off, raises: [].}

# ---- prototypes the C compiler will see (never actually compiled) ----------
proc c_outb(val: uint8, port: uint16) {.importc: "nimos_outb", nodecl.}
proc c_inb(port: uint16): uint8 {.importc: "nimos_inb", nodecl.}
proc c_outw(val: uint16, port: uint16) {.importc: "nimos_outw", nodecl.}
proc c_inw(port: uint16): uint16 {.importc: "nimos_inw", nodecl.}
proc c_outl(val: uint32, port: uint16) {.importc: "nimos_outl", nodecl.}
proc c_inl(port: uint16): uint32 {.importc: "nimos_inl", nodecl.}
proc c_cli() {.importc: "nimos_cli", nodecl.}
proc c_sti() {.importc: "nimos_sti", nodecl.}
proc c_hlt() {.importc: "nimos_hlt", nodecl.}
proc c_pause() {.importc: "nimos_pause", nodecl.}
proc c_readcr0(): uint64 {.importc: "nimos_readcr0", nodecl.}
proc c_writecr0(v: uint64) {.importc: "nimos_writecr0", nodecl.}
proc c_readcr2(): uint64 {.importc: "nimos_readcr2", nodecl.}
proc c_readcr3(): uint64 {.importc: "nimos_readcr3", nodecl.}
proc c_writecr3(v: uint64) {.importc: "nimos_writecr3", nodecl.}
proc c_invlpg(a: uint64) {.importc: "nimos_invlpg", nodecl.}
proc c_lfence() {.importc: "nimos_lfence", nodecl.}
proc c_mfence() {.importc: "nimos_mfence", nodecl.}
proc c_rdmsr(msr: uint32): uint64 {.importc: "nimos_rdmsr", nodecl.}
proc c_wrmsr(msr: uint32, v: uint64) {.importc: "nimos_wrmsr", nodecl.}
proc c_rdtsc(): uint64 {.importc: "nimos_rdtsc", nodecl.}
proc c_sgpr(reg: cint): uint64 {.importc: "nimos_sgpr", nodecl.}

# ---- the actual emitted C definitions (verbatim into nimgenerated.c) -------
{.emit: """
static inline void nimos_outb(uint8_t v, uint16_t p){ __asm__ volatile("outb %%al,%%w[po]" : : [va]"a"(v), [po]"Nd"(p)); }
static inline uint8_t nimos_inb(uint16_t p){ uint8_t r; __asm__ volatile("inb %%w[po],%%al" : [va]"=a"(r) : [po]"Nd"(p)); return r; }
static inline void nimos_outw(uint16_t v, uint16_t p){ __asm__ volatile("outw %%ax,%%w[po]" : : [va]"a"(v), [po]"Nd"(p)); }
static inline uint16_t nimos_inw(uint16_t p){ uint16_t r; __asm__ volatile("inw %%w[po],%%ax" : [va]"=a"(r) : [po]"Nd"(p)); return r; }
static inline void nimos_outl(uint32_t v, uint16_t p){ __asm__ volatile("outl %%eax,%%w[po]" : : [va]"a"(v), [po]"Nd"(p)); }
static inline uint32_t nimos_inl(uint16_t p){ uint32_t r; __asm__ volatile("inl %%w[po],%%eax" : [va]"=a"(r) : [po]"Nd"(p)); return r; }
static inline void nimos_cli(void){ __asm__ volatile("cli" ::: "memory"); }
static inline void nimos_sti(void){ __asm__ volatile("sti" ::: "memory"); }
static inline void nimos_hlt(void){ __asm__ volatile("hlt" ::: "memory"); }
static inline void nimos_pause(void){ __asm__ volatile("pause" ::: "memory"); }
static inline uint64_t nimos_readcr0(void){ uint64_t r; __asm__ volatile("mov %%cr0,%0" : "=r"(r)); return r; }
static inline void nimos_writecr0(uint64_t v){ __asm__ volatile("mov %0,%%cr0" :: "r"(v) : "memory"); }
static inline uint64_t nimos_readcr2(void){ uint64_t r; __asm__ volatile("mov %%cr2,%0" : "=r"(r)); return r; }
static inline uint64_t nimos_readcr3(void){ uint64_t r; __asm__ volatile("mov %%cr3,%0" : "=r"(r)); return r; }
static inline void nimos_writecr3(uint64_t v){ __asm__ volatile("mov %0,%%cr3" :: "r"(v) : "memory"); }
static inline void nimos_invlpg(uint64_t a){ __asm__ volatile("invlpg (%0)" :: "r"(a) : "memory"); }
static inline void nimos_lfence(void){ __asm__ volatile("lfence" ::: "memory"); }
static inline void nimos_mfence(void){ __asm__ volatile("mfence" ::: "memory"); }
static inline uint64_t nimos_rdmsr(uint32_t m){ uint32_t lo,hi; __asm__ volatile("rdmsr" : "=a"(lo), "=d"(hi) : "c"(m)); return ((uint64_t)hi<<32)|lo; }
static inline void nimos_wrmsr(uint32_t m, uint64_t v){ uint32_t lo=(uint32_t)v, hi=(uint32_t)(v>>32); __asm__ volatile("wrmsr" :: "c"(m), "a"(lo), "d"(hi) : "memory"); }
static inline uint64_t nimos_rdtsc(void){ uint32_t lo,hi; __asm__ volatile("rdtsc" : "=a"(lo), "=d"(hi)); return ((uint64_t)hi<<32)|lo; }
static inline uint64_t nimos_sgpr(int r){ uint64_t v; switch(r){case 0: __asm__ volatile("sgq %0":"=m"(v)); break; case 2: __asm__ volatile("slgq %0":"=m"(v)); break; default: v=0;} return v; }
""".}

# ---- ergonomic public wrappers ---------------------------------------------
template outb*(port: uint16, val: uint8) = c_outb(val, port)
template inb*(port: uint16): uint8 = c_inb(port)
template outw*(port: uint16, val: uint16) = c_outw(val, port)
template inw*(port: uint16): uint16 = c_inw(port)
template outl*(port: uint16, val: uint32) = c_outl(val, port)
template inl*(port: uint16): uint32 = c_inl(port)

## Wait one bus cycle -- used between two chained PIC/index register writes.
proc ioWait*() {.inline.} = c_outb(0'u8, 0x80'u16)

template cli*() = c_cli()
template sti*() = c_sti()
template hlt*() = c_hlt()
## Pause hint -- spins without hammering the memory bus (sched idle loop).
template pause*() = c_pause()

template readCr0*(): uint64 = c_readcr0()
template writeCr0*(v: uint64) = c_writecr0(v)
template readCr2*(): uint64 = c_readcr2()   # page-fault faulting address
template readCr3*(): uint64 = c_readcr3()
template writeCr3*(v: uint64) = c_writecr3(v)
template invlpg*(a: uint64) = c_invlpg(a)
template lfence*() = c_lfence()
template mfence*() = c_mfence()
template rdmsr*(msr: uint32): uint64 = c_rdmsr(msr)
template wrmsr*(msr: uint32, v: uint64) = c_wrmsr(msr, v)
template rdtsc*(): uint64 = c_rdtsc()

{.pop.}
