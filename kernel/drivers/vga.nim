# ============================================================================
# kernel/drivers/vga.nim -- classic 80x25 VGA text-mode driver.
#
# Bare-metal Nim trick: the framebuffer lives at PHYSICAL 0xB8000. We access
# it through the HHDM window (physToVirt) rather than hard-coding 0xB8000 as
# a virtual address -- that would only work while Limine's identity map is
# alive, and we deliberately do NOT keep an identity map after initVmm().
#
# Each screen cell = 2 bytes: char + attribute nibble pair (fg | bg<<4).
# The cursor position is programmed through the CRT controller index/data
# port pair (0x3D4/0x3D5) -- remember the ioWait() between index and data!
# ============================================================================

{.push hints: off, raises: [].}

import ../types, ../limine, ../mem
import ../arch/x86_64/io {.all.}

const
  COLS* = 80
  ROWS* = 25
  CRTC_IDX*: Port = 0x3D4
  CRTC_DAT*: Port = 0x3D5
  VGA_PHYS*: uint64 = 0xB8000

type
  Attr* = object
    fg*: uint8
    bg*: uint8

const
  FG_BLACK*     = 0'u8
  FG_BLUE*     = 1'u8
  FG_GREEN*   = 2'u8
  FG_CYAN*      = 3'u8
  FG_RED*      = 4'u8
  FG_MAGENTA* = 5'u8
  FG_BROWN*     = 6'u8
  FG_LGRAY*    = 7'u8
  FG_DGRAY*   = 8'u8
  FG_LBLUE*     = 9'u8
  FG_LGREEN*  = 10'u8
  FG_LCYAN*  = 11'u8
  FG_LRED*      = 12'u8
  FG_LMAG*    = 13'u8
  FG_YELLOW* = 14'u8
  FG_WHITE*     = 15'u8
  BG_BLACK*     = 0'u8
  BG_BLUE*     = 1'u8
  BG_GREEN*   = 2'u8
  BG_CYAN*      = 3'u8
  BG_RED*      = 4'u8
  BG_MAGENTA* = 5'u8
  BG_BROWN*     = 6'u8
  BG_GRAY*     = 7'u8
  BG_LGRAY*   = 8'u8

var vgaBuf: ptr UncheckedArray[uint16]
var row, col: int
var curAttr: uint8 = (BG_BLACK shl 4) or FG_LGRAY
var vgaReady = false

template cell(r, c: int): uint16 =
  (curAttr.uint16 shl 8) or vgaBuf[r * COLS + c] and 0x00FF

proc setCursor(r, c: int) =
  let pos = (r * COLS + c).uint16
  outb(CRTC_IDX, 0x0F)
  ioWait()
  outb(CRTC_DAT, (pos and 0xFF).uint8)
  outb(CRTC_IDX, 0x0E)
  ioWait()
  outb(CRTC_DAT, (pos shr 8).uint8)

proc setColors*(fg, bg: uint8) =
  curAttr = (bg shl 4) or (fg and 0x0F)

proc clearScreen*() =
  var i = 0
  while i < ROWS * COLS:
    vgaBuf[i] = (curAttr.uint16 shl 8) or 0x20'u16
    inc i
  row = 0
  col = 0
  setCursor(0, 0)

proc scrollUp*() =
  var i = 0
  while i < (ROWS - 1) * COLS:
    vgaBuf[i] = vgaBuf[i + COLS]
    inc i
  var j = (ROWS - 1) * COLS
  while j < ROWS * COLS:
    vgaBuf[j] = (curAttr.uint16 shl 8) or 0x20'u16
    inc j
  row = ROWS - 1

proc newline*() =
  col = 0
  inc row
  if row >= ROWS: scrollUp()

proc putcVga*(c: char) =
  if not vgaReady: return
  case c
  of '\n': newline()
  of '\r': col = 0
  of '\b':
    if col > 0:
      dec col
      vgaBuf[row * COLS + col] = (curAttr.uint16 shl 8) or 0x20'u16
  else:
    if col >= COLS: newline()
    vgaBuf[row * COLS + col] = (curAttr.uint16 shl 8) or c.uint16
    inc col
  setCursor(row, col)

proc writeVga*(s: string) =
  for c in s: putcVga(c)

proc initVga*() =
  vgaBuf = cast[ptr UncheckedArray[uint16]](physToVirt(VGA_PHYS))
  vgaReady = true
  clearScreen()

proc cursorPos*(): (int, int) = (row, col)

{.pop.}
