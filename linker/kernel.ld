/* ==========================================================================
 * linker/kernel.ld -- GNU ld script for the NIMOS kernel.
 *
 * Load address: 0xFFFFFFFF80100000 (2 MiB-aligned inside the -2GiB window,
 * which is what Limine's default HHDM-friendly mapping expects and what
 * -mcmodel=kernel supports). Physical placement = wherever Limine loads it;
 * our vmm maps virt-0xFFFFFFFF80000000 back to that physical base via the
 * boot-time relocation table... in THIS revision we rely on Limine's own
 * page tables staying compatible: it maps the kernel image at its chosen
 * virtual address and we rebuild equivalent entries (see vmm.nim comment).
 *
 * Section ordering enforces W^X-ish grouping so the VMM can stamp NX/RO per
 * range using just these boundary symbols.
 * ========================================================================== */

ENTRY(_start)

PHDRS
{
  text PT_LOAD FLAGS(5);   /* R-X */
  data PT_LOAD FLAGS(6);   /* RW- */
}

SECTIONS
{
  . = 0xFFFFFFFF80100000;

  __ktext_start = .;
  .text : {
    *(.text.entry)          /* _start MUST be first byte of the image */
    *(.text .text.*)
  } :text
  . = ALIGN(4096);
  __ktext_end = .;

  __krodata_start = .;
  .rodata : {
    *(.rodata .rodata.*)
    *(.limine_reqs)         /* request array lives in rodata-safe area */
    *(.rodata.str1.*)
  } :text
  .note.gnu.property : { *(.note.gnu.property) }
  . = ALIGN(4096);
  __krodata_end = .;

  __krwdata_start = .;
  .data : {
    *(.data .data.*)
    *(.requests)            /* writable! bootloader writes responses here */
    *(.got) *(.got.plt)
    *(.data.rel.ro.local)
  } :data
  . = ALIGN(4096);
  __krwdata_end = .;

  .bss (NOLOAD) : {
    . = ALIGN(4096);
    __kbss_start = .;
    *(.bss .bss.*)
    *(COMMON)
    . = ALIGN(4096);
    __kbss_end = .;
  } :data

  /DISCARD/ : {
    *(.comment)
    *(.eh_frame)            /* no unwinding support yet; saves ~30% size */
    *(.note .note.*)
    *(.interp)
    *(.dynsym .dynstr .hash .gnu.hash)
  }
}
