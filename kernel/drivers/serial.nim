# ============================================================================
# kernel/drivers/serial.nim -- 16550 UART driver (COM1 @ 0x3F8).
#
# This is the most reliable terminal on bare metal: QEMU's `-serial
# mon:stdio` gives us a full-duplex console with zero graphics dependency.
# Every kernel print* goes here AND to VGA; keyboard input can come from
# either PS/2 or this port (we poll both in tty.nim).
#
# Programming sequence per the 16550 datasheet:
#   1. disable interrupts (IER=0)
#   2. DLAB=1, load divisor (baud = 115200/divisor)
#   3. DLAB=0, set 8N1 line format
#   4. enable FIFOs (FCR), then poll LSR bit 5 (THR empty) before each byte.
# ============================================================================

{.push hints: off, raises: [].}

import ../types, ../mem
import ../arch/x86_64/io {.all.}

const
  COM1*: Port = 0x3F8
  R_RX = 0       # receive buffer (DLAB=0)
  R_TX = 0       # transmit buffer
  R_IER = 1      # interrupt enable
  R_FCR = 2      # FIFO control
  R_LCR = 3      # line control
  R_MCR = 4      # modem control
  R_LSR = 5      # line status
  R_MSR = 6
  R_SCR = 7      # scratch -- used for the presence probe

  LSR_DATA_READY = 0x01
  LSR_OVERRUN    = 0x02
  LSR_THR_EMPTY  = 0x20
  LSR_TX_IDLE    = 0x40

var comBase: Port = COM1
var serialOk = false

proc reg(r: uint8): Port = comBase + r.uint16

proc initSerial*(baudDiv: uint16 = 1) =
  ## 115200 baud with divisor 1 (the default everyone uses in emulators).
  cli()
  outb(reg(R_IER), 0)                       # no UART interrupts yet
  outb(reg(R_LCR), 0x80)                    # DLAB on
  outb(reg(0), (baudDiv and 0xFF).uint8)    # divisor low
  outb(reg(R_IER), (baudDiv shr 8).uint8)   # divisor high
  outb(reg(R_LCR), 0x03)                    # 8 bits, no parity, 1 stop
  outb(reg(R_FCR), 0xC7)                    # enable+reset FIFOs, 14-byte trigger
  outb(reg(R_MCR), 0x0B)                    # DTR|RTS|OUT2
  # --- presence probe: scratch register round-trip --------------------------
  outb(reg(R_SCR), 0xA5)
  serialOk = inb(reg(R_SCR)) == 0xA5
  discard inb(reg(R_RX))                    # drain any pending char
  sti()

proc serialAvailable*(): bool = serialOk
proc serialReadyToRead*(): bool = (inb(reg(R_LSR)) and LSR_DATA_READY) != 0

proc putcSerial*(c: char) =
  if not serialOk: return
  # wait for transmitter holding register to empty (bounded spin so a dead
  # UART can never wedge the whole kernel boot)
  var spins = 100_000
  while (inb(reg(R_LSR)) and LSR_THR_EMPTY) == 0 and spins > 0:
    dec spins
  if spins > 0:
    outb(reg(R_TX), c.uint8)

proc writeSerial*(s: string) =
  for c in s: putcSerial(c)
  if s.len > 0 and s[^1] != '\n': putcSerial('\n')

proc getcSerial*(): int =
  ## -1 when nothing pending. Non-blocking by design: the tty layer polls.
  if serialOk and serialReadyToRead(): inb(reg(R_RX)).int else: -1

{.pop.}
