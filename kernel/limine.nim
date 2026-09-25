# ============================================================================
# kernel/limine.nim -- hand-written bindings for the Limine boot protocol
# (https://github.com/limine-bootloader/limine, revision 2 / v5.x+).
#
# How Limine hands off to us:
#   * Limine parses our ELF64 kernel, maps it into the higher half, enables
#     paging + long mode, and jumps to `_start`.
#   * Before jumping it scans every loaded module's ELF sections for a
#     special section named `.limine_reqs` containing an array of
#     {moduleId: uint64, pointerToRequest: *req} pairs, and fills in each
#     request's response fields.
#
# Nim bare-metal trick #3: we place the *request variables themselves* into
# a custom section with `{.codegenDecl.}`-style attribute emission. The most
# portable way across Nim versions is {.emit.} declaring the variables in C
# with __attribute__((section(".requests"))) -- ".requests" is NOT read-only,
# which the spec requires (the bootloader must write back into them). We
# then reference them from Nim via importc/nodecl.
#
# All structs use fixed-width ints only, so the C backend lays them out
# byte-for-byte like the official limine*.h headers.
# ============================================================================

{.push hints: off, raises: [].}

const
  LIMINE_BASE_REVISION_1*: uint64 = 1
  LIMINE_BASE_REVISION_2*: uint64 = 2
  LIMINE_REQ_OK*: uint64 = 0x5555555555555557'u64  # sentinel written on success

type
  # ---- MEMORY MAP (request tag 0x...; struct per spec §Memory Map) ---------
  LimineMemmapEntry* {.bycopy, pure.} = object
    base*: uint64
    length*: uint64
    kind*: uint32
    unused*: uint32

  LimineMemmapRequest* {.bycopy, pure.} = object
    revision*: uint64
    entry_count*: uint64
    entries*: ptr UncheckedArray[LimineMemmapEntry]

  # ---- HHDM offset ----------------------------------------------------------
  LimineHhdmRequest* {.bycopy, pure.} = object
    revision*: uint64
    offset*: uint64

  # ---- MODULES (our RAM disk images arrive here) ----------------------------
  LimineModule* {.bycopy, pure.} = object
    dataset*: pointer        # opaque bootloader handle
    size*: uint64            # bytes of data below
    address*: uint64         # PHYSICAL address of module data
    string*: cstring         # "nimos-initrd" or similar from limine.cfg

  LimineModulesRequest* {.bycopy, pure.} = object
    revision*: uint64
    module_count*: uint64
    modules*: ptr UncheckedArray[LimineModule]

  # ---- BOOTLOADER INFO / FILE (for cmdline + version banner) ---------------
  LimineFile* {.bycopy, pure.} = object
    revision*: uint64
    dtype*: uint32           # 1 == EXECUTABLE (the kernel ELF itself)
    nodecl0*: uint32
    uri*: cstring
    cmdline*: cstring
    module*: pointer
    msize*: uint64
    entry_point*: pointer

  LimineBootloaderInfoRequest* {.bycopy, pure.} = object
    revision*: uint64
    name*: cstring
    version*: cstring
    file*: ptr LimineFile

  # ---- FRAMEBUFFER (optional; we fall back to VGA text) ---------------------
  LimineFramebufferMode* {.bycopy, pure.} = object
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

  LimineFramebufferRequest* {.bycopy, pure.} = object
    revision*: uint64
    framebuffer_count*: uint64
    framebuffers*: ptr UncheckedArray[LimineFramebufferMode]

  # ---- RSMP / SMP (CPU bringup; parsed but unused in this revision) --------
  LimineSmpEntry* {.bycopy, pure.} = object
    lapic_id*: uint32
    unused*: uint32
    address*: uint64         # physical trampoline address
    processor_id*: uint32

  LimineSmpRequest* {.bycopy, pure.} = object
    revision*: uint64
    flags*: uint32
    unused*: uint32
    entry_count*: uint64
    entries*: ptr UncheckedArray[LimineSmpEntry]

const
  # Memory-map entry kinds (Limine spec table):
  MM_USED*: uint32              = 0
  MM_FREE_MEMORY*: uint32       = 1
  MM_RESERVED*: uint32          = 2
  MM_ACPI_RECLAIMABLE*: uint32  = 3
  MM_NVS*: uint32               = 4
  MM_BAD_MEMORY*: uint32        = 5
  MM_BOOTLOADER_RECLAIMABLE*: uint32 = 6
  MM_KERNEL_AND_MODULES*: uint32     = 7
  MM_BOOTTD*: uint32            = 8

# ---------------------------------------------------------------------------
# The request instances + their .limine_reqs registration, all done in one
# emitted C block. `__attribute__((used))` stops the linker from garbage
# collecting them; the section array is terminated by two zero quads.
# ---------------------------------------------------------------------------
{.emit: """
typedef struct { uint64_t id; void* ptr; } limine_req_pair;

static uint64_t nimos_limine_base_rev __asm__("limine_base_revision") = 2;

static struct { uint64_t revision; uint64_t entry_count; void* entries; }
  nimos_memmap_req __asm__("limine_memmap_request") __attribute__((section(".requests"), used)) = {0};
static struct { uint64_t revision; uint64_t offset; }
  nimos_hhdm_req __asm__("limine_hhdm_request") __attribute__((section(".requests"), used)) = {0};
static struct { uint64_t revision; uint64_t module_count; void* modules; }
  nimos_modules_req __asm__("limine_modules_request") __attribute__((section(".requests"), used)) = {0};
static struct { uint64_t revision; void* name; void* version; void* file; }
  nimos_bootinfo_req __asm__("limine_bootloader_info_request") __attribute__((section(".requests"), used)) = {0};
static struct { uint64_t revision; uint64_t fb_count; void* fbs; }
  nimos_fb_req __asm__("limine_framebuffer_request") __attribute__((section(".requests"), used)) = {0};
static struct { uint64_t revision; uint32_t flags; uint32_t unused; uint64_t entry_count; void* entries; }
  nimos_smp_req __asm__("limine_smp_request") __attribute__((section(".requests"), used)) = {0};

__asm__(".section .limine_reqs, \"aw\", @progbits\n"
        ".p2align 3\n"
        ".quad 0xf9fd4d13, limine_memmap_request\n"
        ".quad 0xedfbbac2, limine_hhdm_request\n"
        ".quad 0x3e7e9117, limine_modules_request\n"
        ".quad 0xb632f13b, limine_bootloader_info_request\n"
        ".quad 0x9ee69ea2, limine_framebuffer_request\n"
        ".quad 0x1936bd4e, limine_smp_request\n"
        ".quad 0, 0\n"
        ".previous");
""".}

# Nim-side accessors that point at the very same C objects above.
var gLimineMemmap* {.importc: "nimos_memmap_req", header: "", nodecl.}: LimineMemmapRequest
var gLimineHhdm* {.importc: "nimos_hhdm_req", header: "", nodecl.}: LimineHhdmRequest
var gLimineModules* {.importc: "nimos_modules_req", header: "", nodecl.}: LimineModulesRequest
var gLimineBootinfo* {.importc: "nimos_bootinfo_req", header: "", nodecl.}: LimineBootloaderInfoRequest
var gLimineFb* {.importc: "nimos_fb_req", header: "", nodecl.}: LimineFramebufferRequest
var gLimineSmp* {.importc: "nimos_smp_req", header: "", nodecl.}: LimineSmpRequest

proc limineBaseRevisionOk*(): bool = gLimineMemmap.revision == LIMINE_REQ_OK

proc hhdmOffset*(): uint64 =
  ## The virtual bias Limine chose for the higher-half direct map. Physical
  ## address P is readable/writable at (P + hhdmOffset()) until we swap in
  ## our own page tables (which keep the same bias -- see vmm.nim).
  gLimineHhdm.offset

template physToVirt*(pa: uint64): uint64 = pa + hhdmOffset()

proc memmapCount*(): int = int(gLimineMemmap.entry_count)
proc memmapEntry*(i: int): LimineMemmapEntry =
  gLimineMemmap.entries[i]

proc modulesCount*(): int = int(gLimineModules.module_count)
proc moduleAt*(i: int): LimineModule = gLimineModules.modules[i]

{.pop.}
