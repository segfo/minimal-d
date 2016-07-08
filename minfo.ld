ENTRY(_start)

SECTIONS {
	. = 0x400000;
	.text : { *(.text) *(.text.*) }

	.minfo_beg :{ _minfo_beg = 0; }
	.minfo : {*(.minfo) }
	.minfo_end :{ _minfo_end = 0; }

	.data : { *(.data) *(.data.*) }
	.rodata : { *(.rodata) }

	.bss : {
		*(COMMON)
		*(.bss)
	}
}
