/* The extension is appended without moving any vendor ELF section/address. */
SECTIONS {
    .text PREROLL_BASE : {
        KEEP(*(.text.duration))
        duration_end = .;
        . = 0x200;
        KEEP(*(.text.creation))
    }
    /DISCARD/ : { *(.comment) *(.note*) *(.ARM.attributes) *(.ARM.exidx*) *(.ARM.extab*) }
}
ASSERT(duration_end - PREROLL_BASE <= 0x200, "preroll duration helper exceeds reserved space")
