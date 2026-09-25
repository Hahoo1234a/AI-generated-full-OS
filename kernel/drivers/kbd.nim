# ============================================================================
# kernel/drivers/kbd.nim -- PS/2 keyboard (8042 controller) driver, polled.
#
# We deliberately POLL instead of installing an IRQ1 handler: it keeps this
# revision free of the IDT/8259 plumbing, and QEMU delivers scan codes to the
# 8042 output buffer regardless. A future version moves this into the ISR and
# wakes a blocked tty reader via the scheduler.
#
# Scan code set 1 highlights we handle:
#   * make codes for letters/digits/punctuation -> ASCII table below
#   * E0-prefixed codes are swallowed (arrows/home cluster -- not needed)
#   * release codes = make | 0x80 (ignored except shift tracking)
#   * F1 (0x39) is wired to color-cycle so you can SEE the driver working.
#
# Bare-metal Nim trick: raw circular buffer of fixed size in static memory --
# no ring/seq types, no allocation, safe from interrupt context by design
# (single producer here, single consumer in tty.nim).
# ============================================================================

{.push hints: off, raises: [].}

import ../types, ../mem
import ../arch/x86_64/io {.all.}

const
  KBD_DATA*: Port = 0x60
  KBD_STAT*: Port = 0x64
  STAT_OUT_FULL = 0x01
  STAT_IN_FULL  = 0x02
  BUF_SIZE = 128

  # --- unshifted scan-code-set-1 -> ASCII ------------------------------------
type
  KeyMapEntry = object
    sc: uint8
    ch: char

var kbdBuf: array[BUF_SIZE, uint8]
var rd, wr: int
var lShift, rShift, capsLk = false
var sawE0 = false
var kbdReady = false

proc scToAscii(sc: uint8): char =
  ## Returns '\0' when the code has no printable meaning (callers test < 0
  ## style via `.int >= 0`? No -- they test `a >= '\0'`... see pollKbd).
  let shifted = lShift or rShift or capsLk
  result = '\0'
  case sc
  of 0x02: result = if shifted: '!' else: '1'
  of 0x03: result = if shifted: '@' else: '2'
  of 0x04: result = if shifted: '#' else: '3'
  of 0x05: result = if shifted: '$' else: '4'
  of 0x06: result = if shifted: '%' else: '5'
  of 0x07: result = if shifted: '^' else: '6'
  of 0x08: result = if shifted: '&' else: '7'
  of 0x09: result = if shifted: '*' else: '8'
  of 0x0A: result = if shifted: '(' else: '9'
  of 0x0B: result = if shifted: ')' else: '0'
  of 0x0C: result = if shifted: '_' else: '-'
  of 0x0D: result = if shifted: '+' else: '='
  of 0x0E: result = '\b'          # Backspace
  of 0x0F: result = '\t'          # Tab
  of 0x10..0x19:                  # Q W E R T Y U I O P
    const qwerty = "qwertyuiop"
    result = qwerty[sc.int - 0x10]
  of 0x1A: result = '['           # [  (scan 0x1A wins over the letter row)
  of 0x1B: result = ']'           # ]
  of 0x1E..0x25, 0x27, 0x28:      # A S D F G H J K
    result = chr(ord('a') + (sc.int - 0x1E))
  of 0x26: result = 'l'           # L sits between K and ; in scan order
  of 0x2A: result = chr(92)      # backslash '\\' (next to Enter on ISO) (next to Enter on ISO layout)
  of 0x2C..0x31:                  # Z X C V B N
    result = chr(ord('z') + (sc.int - 0x2C))
  of 0x32: result = 'm'           # M
  of 0x33: result = if shifted: '<' else: ','
  of 0x34: result = if shifted: '>' else: '.'
  of 0x35: result = if shifted: '?' else: '/'
  of 0x39: result = ' '           # Spacebar
  of 0x1C: result = '\n'          # Enter
  of 0x2B: result = if shifted: ':' else: ';'
  else: discard
  if shifted and result >= 'a' and result <= 'z':
    result = chr(result.ord - 32)

proc pushKey(code: uint8) =
  let nwr = (wr + 1) mod BUF_SIZE
  if nwr != rd:                  # drop on overflow rather than corrupting
    kbdBuf[wr] = code
    wr = nwr

proc pollKbd*() =
  ## Drain the 8042 output buffer; call at least every ~1 ms for no key loss.
  while (inb(KBD_STAT) and STAT_OUT_FULL) != 0:
    let code = inb(KBD_DATA)
    if code == 0xE0:
      sawE0 = true
      continue
    if sawE0:
      sawE0 = false
      continue                   # swallow all E0-prefixed extended codes
    # shift tracking (make AND release both toggle our model state)
    case code
    of 0x2A: lShift = true
    of 0x36: rShift = true
    of 0xAA: lShift = false
    of 0xB6: rShift = false
    of 0x3A: capsLk = not capsLk  # CapsLock make toggles; release 0xBA ignored
    else:
      if (code and 0x80) == 0:   # make code only
        let a = scToAscii(code)
        if a != '\0':
          pushKey(a.uint8)
        elif code == 0x01:       # ESC: push as \x1b so shell can see it
          pushKey(0x1B)

proc initKbd*() =
  # flush any stale data, enable the port (command 0xAE = enable first port)
  var spins = 10000
  while (inb(KBD_STAT) and STAT_OUT_FULL) != 0 and spins > 0:
    discard inb(KBD_DATA)
    dec spins
  # wait until input buffer empty before sending a command
  spins = 10000
  while (inb(KBD_STAT) and STAT_IN_FULL) != 0 and spins > 0: dec spins
  outb(KBD_STAT, 0xAE)
  kbdReady = true

proc kbdInitialized*(): bool = kbdReady

proc getcKbd*(): int =
  ## Non-blocking pop from the decoded ASCII queue; -1 when empty.
  if rd == wr: return -1
  result = kbdBuf[rd].int
  rd = (rd + 1) mod BUF_SIZE

{.pop.}
