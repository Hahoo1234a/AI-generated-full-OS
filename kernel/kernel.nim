# ============================================================================
# kernel/kernel.nim -- THE ENTRY POINT. `nim c` compiles THIS file; its C
# backend emits a `main()` which we never call -- instead our asm `_start`
# (below) sets up a stack and calls Nim's real init (`NimMain`) then ours.
#
# Boot order matters and is documented inline. The whole sequence runs with
# interrupts OFF until the shell starts polling devices deliberately.
#
# Nim bare-metal trick #1: providing our own `_start`. Nim's standalone
# runtime expects to be entered via `main(argc, argv)`; on freestanding x86-64
# there is none. We emit raw assembly that becomes the ELF entry symbol,
# honoring the SysV ABI (16-byte stack alignment) before calling into Nim.
# ============================================================================

{.push hints: off, raises: [].}

import types, limine, mem
import mm/pmm, mm/vmm, mm/kmalloc
import drivers/[serial, vga]
import posix/[vfs, ramfs, tty]
import posix/syscall as sc
import shell/shell

proc kputs(s: string) =
  var i = 0
  while i < s.len:
    putcSerial(s[i])
    putcVga(s[i])
    inc i

proc banner() =
  setColors(FG_LCYAN, BG_BLACK)
  kputs("\n")
  kputs("  _   _ _                             \n")
  kputs(" | \\ | (_)_ __   ___  ___ _ __        \n")
  kputs(" |  \\| | | '_ \\ / _ \\/ __| '_ \\   OS  \n")
  kputs(" | |\\  | | | | |  __/ (__| |_) |       \n")
  kputs(" |_|  \\_|_|_| |_|\\___|\\___| .__/  v0.1  \n")
  kputs("                           |_|           \n")
  kputs(" written in Nim -- no libc, no GC, no mercy\n\n")
  setColors(FG_LGRAY, BG_BLACK)

proc panicAt(msg: string) =
  setColors(FG_WHITE, BG_RED)
  kputs("KERNEL PANIC: " & msg & "\n")
  setColors(FG_LGRAY, BG_BLACK)
  while true: hlt()

# ---------------------------------------------------------------------------
# The hand-written entry stub. It:
#   1. preserves whatever Limine passed (we read requests from statics),
#   2. points RSP at a fresh page-aligned kernel stack in BSS,
#   3. zeroes rbp (nice for debuggers),
#   4. calls NimMain (the generated runtime initializer),
#   5. calls our nimos_main.
# ---------------------------------------------------------------------------
{.emit: """
extern void NimMain(void);
extern void nimos_main(void);

__asm__(
".section .text.entry, \"ax\", @progbits\n"
".global _start\n"
"_start:\n"
"  cli\n"
"  lea nimos_kstack_top(%rip), %rsp\n"
"  andq $-16, %rsp\n"
"  xorl %ebp, %ebp\n"
"  call NimMain\n"
"  call nimos_main\n"
"1: hlt\n"
"  jmp 1b\n"
".section .bss\n"
".align 4096\n"
"nimos_kstack:\n"
"  .zero 65536\n"
"nimos_kstack_top:\n");
""".}

proc nimosMain() {.importc: "nimos_main", nodecl.}

proc mainBody() {.exportc: "nimos_main", used.} =
  banner()
  kputs("[0/7] Limine handoff... ")
  if not limineBaseRevisionOk():
    panicAt("Limine base revision unsupported")
  kputs("ok\n")

  kputs("[1/7] PMM (bitmap over memmap)... ")
  initPmm()
  if not pmmInitialized():
    panicAt("PMM init failed - no usable free memory region")
  kputs($freeFrameCount() & " frames free of " & $totalFrameCount() & "\n")

  kputs("[2/7] VMM (new CR3, HHDM preserved)... ")
  initVmm()
  if pml4Phys == 0: panicAt("vmm alloc failed")
  kputs("ok (HHDM @ 0x" & $hhdmOffset() & ")\n")

  kputs("[3/7] kmalloc heap... ")
  initKheap()
  let probe = kmalloc(128)
  if probe.isNil: panicAt("heap cannot allocate 128B")
  kfree(probe)
  kputs("ok\n")

  kputs("[4/7] console (serial + VGA)... ")
  initTty()
  kputs((if serialAvailable(): "uart ok" else: "uart absent") & ", vga ok\n")

  kputs("[5/7] VFS root + devfs... ")
  initVfs()
  sc.setRoot(rootIno)
  registerDevfs()
  kputs("/dev/{tty,null,zero}\n")

  kputs("[6/7] mounting RAM disk modules... ")
  initRamfs()
  let rdino = resolvePath("/rd")
  if rdino >= 0:
    let d = getNode(rdino)
    kputs($d.nChildren & " entries under /rd\n")
  else:
    kputs("no /rd (no modules?)\n")

  kputs("[7/7] starting NIMSH...\n")
  runShell(true)

# Nim requires a top-level `main` even though we never use it; make it trivial.
when isMainModule:
  discard "entry is _start -> nimos_main; this module body is inert"

{.pop.}
