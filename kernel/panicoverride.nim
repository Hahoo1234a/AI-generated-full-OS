# ============================================================================
# kernel/panicoverride.nim -- REQUIRED for every --os:standalone Nim build.
#
# The Nim runtime (lib/system/fatal.nim) hard-wires, for standalone targets:
#     include "$projectpath/panicoverride"
# and then calls `panic(msg)` / `rawoutput(msg)` from sysFatal(). Without this
# file next to the main module you get "cannot open file: panicoverride".
#
# We keep messages ASCII-only because no console driver is guaranteed alive
# when a panic fires during early boot; raw serial would be ideal but risks
# recursion if the panicking code WAS the serial driver. So: halt.
# ============================================================================

proc panic*(s: string) {.noSideEffect, noreturn.} =
  # swallow the message; a future revision pushes it into a log page first
  var dummy = s.len
  while true: discard

proc rawoutput*(s: string) {.noSideEffect.} =
  var dummy = s.len
  discard dummy
