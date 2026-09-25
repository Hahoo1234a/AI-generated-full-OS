# ============================================================================
# kernel/shell/shell.nim -- NIMSH: the built-in command interpreter.
#
# Runs in ring-0 (kernel context) for now; every command is a proc call that
# goes through the SAME syscall layer userland would use, so the shell doubles
# as our regression test suite for POSIX semantics.
#
# Commands: help ls cat echo pwd write rm mkdir stat mem kstack color clear
#           uname reboot halt about exit
# `exit` drops to the idle loop (hlt polling) until you press Ctrl-C... which
# we don't have yet, so exit == reboot-to-halt for this revision.
# ============================================================================

{.push hints: off, raises: [].}

import ../types, ../mem, ../limine,
       ../arch/x86_64/io as pio, ../mm/pmm, ../mm/kmalloc,
       ../posix/vfs, ../posix/syscall, ../posix/tty,
       ../drivers/vga, ../drivers/serial, ../drivers/kbd

const
  PROMPT* = "nimsh> "
  HIST_LEN = 8

var hist: array[HIST_LEN, string]
var histN = 0
var histPos = 0
var inputBuf: array[LINE_MAX, char]
var inputLen = 0
var running = true
var fgColor = FG_LGRAY
var bgColor = BG_BLACK

# Busy-wait backoff used by the line editor when both PS/2 and UART queues are
# empty. Templates must be defined BEFORE first use in Nim (no forward refs),
# which is why this lives up here instead of next to the other helpers below.
template pauseSpinShell() =
  var s = 0
  while s < 5000: inc s   # ~microsecond-ish backoff; replaced by hlt/idle later

proc parseIntSafe(s: string): int =
  result = 0
  for c in s:
    if c < '0' or c > '9': return -1
    result = result * 10 + (c.ord - '0'.ord)

proc splat(s: string): seq[string] =
  result = @[]
  var cur = ""
  var i = 0
  while i < s.len:
    if s[i] == ' ':
      if cur.len > 0: result.add(cur); cur = ""
    else:
      cur.add(s[i])
    inc i
  if cur.len > 0: result.add(cur)

proc outl(s: string) =
  writeVga(s); writeVga("\n")
  writeSerial(s)

proc readLine(): string =
  ## Blocking line editor with history recall via Up-arrow-ish keys:
  ## we map Ctrl-P/N because arrow codes are E0-swallowed by kbd.nim.
  result = ""
  inputLen = 0
  while true:
    pollKbd()
    var c = getcKbd()
    if c < 0: c = getcSerial()
    if c < 0:
      pauseSpinShell()
      continue
    let ch = char(c.uint8)
    case ch
    of '\r', '\n':
      outl("")
      return $cast[cstring](addr inputBuf[0])
    of 0x7F.char, '\b':
      if inputLen > 0:
        dec inputLen
        inputBuf[inputLen] = '\0'
        writeVga("\b \b"); putcSerial('\b'); putcSerial(' '); putcSerial('\b')
    of '\x10': # Ctrl-P: prev history
      if histPos < histN:
        inc histPos
        writeVga("\r" & PROMPT & hist[histN - histPos])
        inputLen = 0
        for cc in hist[histN - histPos]:
          inputBuf[inputLen] = cc; inc inputLen
        inputBuf[inputLen] = '\0'
    of '\x0E': # Ctrl-N: next
      if histPos > 0:
        dec histPos
        var s = if histPos == 0: "" else: hist[histN - histPos]
        writeVga("\r" & PROMPT & s)
        inputLen = 0
        for cc in s: inputBuf[inputLen] = cc; inc inputLen
        inputBuf[inputLen] = '\0'
    of '\x03': # ^C aborts current line
      outl("^C")
      inputLen = 0
      inputBuf[0] = '\0'
      writeVga(PROMPT)
    else:
      if inputLen < LINE_MAX - 1 and ch >= ' ' and ch <= '~':
        inputBuf[inputLen] = ch
        inc inputLen
        inputBuf[inputLen] = '\0'
        putcVga(ch); putcSerial(ch)

proc cmdHelp() =
  outl("NIMSH commands:")
  outl("  ls [path]     list directory (getdents)")
  outl("  cat <file>    dump file contents")
  outl("  echo <args>   print args")
  outl("  write <p> <t> create/truncate file with text")
  outl("  rm <path>     unlink")
  outl("  mkdir <path>  make directory")
  outl("  stat <path>   show inode info")
  outl("  mem           PMM + heap stats")
  outl("  kstack        show stack watermark (demo)")
  outl("  color <fg> [bg] set palette (0-15)")
  outl("  clear         clear screen")
  outl("  uname         system id string")
  outl("  about         project blurb")
  outl("  reboot/halt   power ops (QEMU exits)")
  outl("  exit          leave shell (halts CPU)")

proc cmdLs(args: seq[string]) =
  let path = if args.len > 1: args[1] else: "/"
  let fd = sysOpen(path.cstring, O_RDONLY or 0x0040'u32, 0).cint
  # open() on a dir needs no O_CREAT really; emulate opendir via direct walk:
  let ino = resolvePath(path)
  if ino < 0: outl("ls: " & path & ": No such file or directory"); return
  let d = getNode(ino)
  if d.kind != nkDir: outl("ls: not a directory"); return
  var i = 0
  while i < d.nChildren:
    let c = getNode(d.children[i])
    if c.isNil: inc i; continue
    let tag = case c.kind
              of nkDir: "/"
              of nkCharDev: "c"
              of nkFile: " "
    outl("  " & getName(c.name) & tag & "  " & $c.size & "B")
    inc i

proc cmdCat(args: seq[string]) =
  if args.len < 2: outl("usage: cat <file>"); return
  let fd = sysOpen(args[1].cstring, O_RDONLY, 0)
  if fd < 0: outl("cat: cannot open " & args[1]); return
  var buf: array[256, char]
  while true:
    let n = sysRead(fd.cint, addr buf[0], 256)
    if n <= 0: break
    var i = 0
    while i < n.int:
      putcVga(buf[i]); putcSerial(buf[i]); inc i
  discard sysClose(fd.cint)

proc cmdEcho(args: seq[string]) =
  var s = ""
  var i = 1
  while i < args.len:
    if i > 1: s.add(" ")
    s.add(args[i]); inc i
  outl(s)

proc cmdWrite(args: seq[string]) =
  if args.len < 3: outl("usage: write <path> <text...>"); return
  var text = ""
  var i = 2
  while i < args.len:
    if i > 2: text.add(" ")
    text.add(args[i]); inc i
  let fd = sysOpen(args[1].cstring, O_WRONLY or O_CREAT or O_TRUNC, 0x01A4'u32)
  if fd < 0: outl("write: failed (" & $fd & ")"); return
  discard sysWrite(fd.cint, addr text[0], text.len.csize)
  discard sysClose(fd.cint)
  outl("wrote " & $text.len & " bytes to " & args[1])

proc cmdRm(args: seq[string]) =
  if args.len < 2: outl("usage: rm <path>"); return
  let e = sysUnlink(args[1].cstring)
  if e != 0: outl("rm: error " & $e)

proc cmdMkdir(args: seq[string]) =
  if args.len < 2: outl("usage: mkdir <path>"); return
  let e = sysMkdir(args[1].cstring, 0x01ED'u32)
  if e != 0: outl("mkdir: error " & $e)

proc cmdStat(args: seq[string]) =
  if args.len < 2: outl("usage: stat <path>"); return
  var st: Stat
  let e = sysStat(args[1].cstring, addr st)
  if e != 0: outl("stat: error " & $e); return
  outl("  size=" & $st.st_size & " mode=0o" & $st.st_mode &
       " ino=" & $st.st_ino & " links=" & $st.st_nlink)

proc cmdMem() =
  let (arena, live, peak) = heapStats()
  outl("PMM: " & $freeFrameCount() & "/" & $totalFrameCount() &
       " frames free (" & $(freeFrameCount() * 4) & " MiB)")
  outl("heap arena " & $arena & "B, live " & $live & "B, peak " & $peak & "B")

proc cmdKstack() =
  var probe: array[64, uint64]
  let sp = cast[uint64](addr probe[0])
  outl("shell stack pointer ~ 0x" & $sp)

proc cmdColor(args: seq[string]) =
  if args.len < 2: outl("usage: color <fg0-15> [bg0-7]"); return
  let fg = parseIntSafe(args[1])
  let bg = if args.len > 2: parseIntSafe(args[2]) else: bgColor.int
  if fg >= 0 and fg < 16 and bg >= 0 and bg < 8:
    fgColor = fg.uint8; bgColor = bg.uint8
    setColors(fgColor, bgColor.uint8)
    outl("palette updated")
  else:
    outl("color: bad values")

proc haltCpu() =
  while true: pio.hlt()

proc cmdUname() = outl("Nimos 0.1.0 x86_64 Limine/Nim standalone")
proc cmdAbout() =
  outl("Nimos -- an OS written entirely in Nim.")
  outl("Kernel, drivers, VFS, shell: all --mm:none, all freestanding.")

proc cmdReboot() =
  outl("rebooting (triple fault)...")
  # keyboard controller reset pulse
  var tries = 100000
  while (pio.inb(0x64'u16) and 0x02) != 0 and tries > 0: dec tries
  pio.outb(0x64'u16, 0xFE'u8)
  haltCpu()

proc cmdHalt() =
  outl("halting.")
  haltCpu()

proc runShell*(banner: bool = true) =
  if banner:
    setColors(FG_LCYAN, BG_BLACK)
    outl("Welcome to NIMSH -- type 'help'.")
    setColors(fgColor, bgColor)
  running = true
  while running:
    writeVga(PROMPT)
    let line = readLine()
    if line.len == 0: continue
    if histN < HIST_LEN:
      hist[histN] = line; inc histN
    else:
      var i = 0
      while i < HIST_LEN - 1:
        hist[i] = hist[i+1]; inc i
      hist[HIST_LEN-1] = line
    histPos = 0
    let args = splat(line)
    if args.len == 0: continue
    case args[0]
    of "help": cmdHelp()
    of "ls": cmdLs(args)
    of "cat": cmdCat(args)
    of "echo": cmdEcho(args)
    of "write": cmdWrite(args)
    of "rm": cmdRm(args)
    of "mkdir": cmdMkdir(args)
    of "stat": cmdStat(args)
    of "mem": cmdMem()
    of "kstack": cmdKstack()
    of "color": cmdColor(args)
    of "clear": clearScreen()
    of "uname": cmdUname()
    of "about": cmdAbout()
    of "reboot": cmdReboot()
    of "halt": cmdHalt()
    of "exit": running = false
    else: outl(args[0] & ": command not found")
  outl("shell exited -- halting.")
  haltCpu()

{.pop.}
