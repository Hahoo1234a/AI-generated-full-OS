# ============================================================================
# kernel/posix/tty.nim -- the POSIX terminal layer: line discipline + fd 0/1/2
#
# This is what makes `read(0, buf, n)` behave like a real tty instead of raw
# keyboard spew: canonical mode with ERASE(^H)/KILL(^U), echo, and EOF (^D).
# The read path BLOCKS (spins with pause) until a full line is available --
# true blocking needs the scheduler; this spin version is honest about it.
#
# fd convention we install at boot (kernel_init calls initStdFds):
#   0 = stdin  -> ttyRead
#   1 = stdout -> ttyWrite (VGA+serial)
#   2 = stderr -> same as stdout but we could split colors later
# ============================================================================

{.push hints: off, raises: [].}

import ../types, ../mem, vfs
import ../drivers/serial, ../drivers/kbd, ../drivers/vga

const
  LINE_MAX* = 256
  CTRL_C    = '\x03'
  CTRL_D    = '\x04'
  CTRL_U    = '\x15'
  CTRL_H    = '\x08'

var lineBuf: array[LINE_MAX, char]
var lineLen = 0          # chars typed on current line
var cooked: array[LINE_MAX, char]
var cookLen = 0          # bytes ready for read()
var cookPos = 0          # consumer cursor
var ttyReady = false

proc putcharEcho(c: char) =
  putcVga(c)
  putcSerial(c)

proc pollInput() =
  ## Pull one byte from either device into the line editor. Called by every
  ## read/write so the shell stays responsive without an event loop.
  pollKbd()
  var c = getcKbd()
  if c < 0: c = getcSerial()
  if c < 0: return
  let ch = char(c.uint8)
  case ch
  of '\r', '\n':
    # finish line: move to cooked buffer, echo newline
    if lineLen >= LINE_MAX - 1: return
    cooked[cookLen] = '\n'; inc cookLen
    var i = 0
    while i < lineLen:
      cooked[cookLen] = lineBuf[i]; inc cookLen; inc i
    lineLen = 0
    putcharEcho('\n')
  of CTRL_H:
    if lineLen > 0:
      dec lineLen
      for cc in "\b \b": putcharEcho(cc)
  of CTRL_U:
    while lineLen > 0:
      for cc in "\b \b": putcharEcho(cc)
      dec lineLen
  of CTRL_D:
    # EOF semantics: only meaningful on an empty pending line
    if lineLen == 0 and cookPos == cookLen:
      cooked[cookLen] = '\0'   # sentinel consumed as EOF marker
      inc cookLen
  else:
    if lineLen < LINE_MAX - 1:
      lineBuf[lineLen] = ch
      inc lineLen
      putcharEcho(ch)

template pauseSpin() =
  var s = 0
  while s < 2000: inc s   # ~microsecond-ish backoff; replaced by hlt later

proc ttyRead*(buf: pointer, count: int): int =
  ## POSIX read(2) on fd 0: returns >=1 bytes when a line is pending; blocks
  ## otherwise. Returns 0 (EOF) after ^D on an empty line.
  if not ttyReady: return -1
  # wait for data
  while cookPos >= cookLen:
    pollInput()
    pauseSpin()
  if cooked[cookPos] == '\0' and cookLen == cookPos + 1:
    cookPos = 0; cookLen = 0
    return 0                     # EOF
  result = min(count, cookLen - cookPos)
  copyMem(buf, addr cooked[cookPos], result)
  cookPos += result
  if cookPos >= cookLen:
    cookPos = 0; cookLen = 0     # reset ring between lines

proc ttyWrite*(buf: pointer, count: int): int =
  if not ttyReady: return -1
  let p = cast[ptr UncheckedArray[char]](buf)
  var i = 0
  while i < count:
    putcVga(p[i])
    putcSerial(p[i])
    inc i
  count

proc devNullRead*(buf: pointer, n: int): int = 0
proc devNullWrite*(buf: pointer, n: int): int = n
proc zeroRead*(buf: pointer, n: int): int =
  zeroMem(buf, n); n
proc consoleRead*(buf: pointer, n: int): int = ttyRead(buf, n)
proc consoleWrite*(buf: pointer, n: int): int = ttyWrite(buf, n)

proc initTty*() =
  initSerial()
  initKbd()
  ttyReady = true

proc registerDevfs*() =
  ## Creates /dev/{tty,null,zero} once root exists. Call after initVfs().
  discard vfsMkdir("/", "dev")
  discard vfsRegisterDev("/dev", "tty", consoleRead, consoleWrite)
  discard vfsRegisterDev("/dev", "null", devNullRead, devNullWrite)
  discard vfsRegisterDev("/dev", "zero", zeroRead, devNullWrite)


{.pop.}
