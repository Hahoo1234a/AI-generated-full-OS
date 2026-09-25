# ============================================================================
# kernel/limine.nim -- hand-written bindings for the parts of the Limine
# boot protocol (https://github.com/limine-bootloader/limine, v5.x / revision
# 2.0) that our kernel consumes: the base revision tag, the memory-map
# request and the framebuffer request.
#
# Why a `.data` section for requests?  The Limine spec requires requests to
# live in a non-read-only section so the bootloader can write back `done`.
# We achieve that with `{.section: ".requests".}` -- a Nim pragma that maps
# straight onto GCC's `__attribute__((section(".requests")))`.
#
# Bare-metal Nim trick #3: every struct field is declared `packed` semantics
# by construction -- we only use fixed-width integer types and explicit
# padding arrays so the C backend lays them out identically to the spec.
# ============================================================================

{.push hints: off.}

const
  LIMINE_MAGIC*: cstring = "LIMITSMM"   # first 8 bytes of every limine_struct
  LIMINE_REVISION*: uint64 = 2          # we implement protocol revision 2

type
  LimineFile* {.bycopy.} = object
    revision*: uint64
    dtype*: uint32          # 1 = EXECUTABLE / kernel ELF itself
    uri*: cstring           # e.g. "boot//BOOTFS/nimos.bin"
    cmdline*: cstring       # kernel command line from limine.cfg
    module*: pointer        # multiboot-style module (unused)
    msize*: uint64
    entry_point*: pointer   # physical address where control was transferred

  LimineBootdevRequest* {.bycopy.} = object
    revision*: uint64
    # response
    kind*: uint32
    unused*: uint32
    partition_uuid*: array[16, uint8]
    parent_uuid*: array[16, uint8]

  LimineMemmapEntry* {.bycopy.} = object
    base*: uint64
    length*: uint64
    kind*: uint32

  const MEMMAP_MAX* = 512
  LimineMemmapRequest* {.bycopy.} = object
    revision*: uint64
    entry_count*: uint64
    entries*: ptr UncheckedArray[LimineMemmapEntry]

  # --- framebuffer (we only need linear RGB / BGX + pitch) ------------------
  LimineFramebufferMode* {.bycopy.} = object
    width*: uint32
    height*: uint32
    pitch*: uint32
    bpp*: uint32
    red_mask_size*: uint8
    red_mask_shift*: uint8
    green_mask_size*: uint8
    green_mask_shift*: uint8
    blue_mask_size*: uint8
    blue_mask_shift*: uint8
    unused*: array[7, uint8]
    memory_model*: uint8     # 1 = RGB, 2 = BGR
    address*: pointer

  LimineFramebufferRequest* {.bycopy.} = object
    revision*: uint64
    mode_count*: uint32
    modes*: ptr UncheckedArray[LimineFramebufferMode]
    highest_mode*: bool

  # --- rsdp (ACPI) -----------------------------------------------------------
  LimineRsdpRequest* {.bycopy.} = object
    revision*: uint64
    address*: pointer

  # --- HHDM offset ("higher-half direct map") --------------------------------
  LimineHhdmRequest* {.bycopy.} = object
    revision*: uint64
    offset*: uint64

# Memory-map entry kinds (Limine spec §Memory Map).
const
  MM_USED*: uint32 = 0
  MM_FREE*: uint32 = 1
  MM_RESERVED*: uint32 = 2
  MM_ACPI_RECLAIMABLE*: uint32 = 3
  MM_ACPI_NVS*: uint32 = 4
  MM_BAD_MEMORY*: uint32 = 5
  MM_BOOTLOADER_RECLAIMABLE*: uint32 = 6
  MM_KERNEL_AND_MODULES*: uint32 = 7

# The actual request instances. `extern` gives them stable C symbol names so
# the assembly stub in boot.s can reference them without name mangling.
var limineRevision* {.importc: "LIMINE_BASE_REVISION", extern: "limine_base_rev", section: ".requests.":} =
  2'u64

var limineMemmapReq* {.extern: "limine_memmap_request", section: ".requests":} =
  LimineMemmapRequest(revision: 2)

var limineFramebufferReq* {.extern: "limine_fb_request", section: ".requests":} =
  LimineFramebufferRequest(revision: 0)

var limineHhdmReq* {.extern: "limine_hhdm_request", section: ".requests":} =
  LimineHhdmRequest(revision: 0)

var limineRsdpReq* {.extern: "limine_rsdp_request", section: ".requests":} =
  LimineRsdpRequest(revision: 0)

var limineBootdevReq* {.extern: "limine_bootdev_request", section: ".requests":} =
  LimineBootdevRequest(revision: 0)

{.pop.}
