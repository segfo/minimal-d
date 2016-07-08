module bare_metal.idt;

enum ICW1_ICW4 = 0x01;/* ICW4 (not) needed */
enum ICW1_SINGLE = 0x02;/* Single (cascade) mode */
enum ICW1_INTERVAL4 = 0x04;/* Call address interval 4 (8) */
enum ICW1_LEVEL = 0x08;/* Level triggered (edge) mode */
enum ICW1_INIT = 0x10;/* Initialization - required! */

enum ICW4_8086 = 0x01;/* 8086/88 (MCS-80/85) mode */
enum ICW4_AUTO = 0x02;/* Auto (normal) EOI */
enum ICW4_BUF_SLAVE = 0x08;/* Buffered mode/slave */
enum ICW4_BUF_MASTER = 0x0C;/* Buffered mode/master */
enum ICW4_SFNM = 0x10;/* Special fully nested (not) */

enum PIC1 = 0x20;/* IO base address for master PIC */
enum PIC2 = 0xA0;/* IO base address for slave PIC */
enum PIC1_COMMAND = PIC1;
enum PIC1_DATA = (PIC1+1);
enum PIC2_COMMAND = PIC2;
enum PIC2_DATA = (PIC2+1);

enum IRQOffset = 0x20;

void mapPic() {
	ubyte a, b;
	asm {
		out PIC1_DATA, AL;
		mov [a], AL;
		out PIC2_DATA, AL;
		mov [b], AL;

		mov AL, ICW1_INIT + ICW1_ICW4;
		out PIC1_COMMAND, AL;
		out PIC2_COMMAND, AL;

		mov AL, IRQOffset;
		out PIC1_DATA, AL;

		mov AL, IRQOffset + 8;
		out PIC2_DATA, AL;

		mov AL, 4;
		out PIC1_DATA, AL;

		mov AL, 2;
		out PIC2_DATA, AL;

		mov AL, ICW4_8086;
		out PIC1_DATA, AL;
		out PIC2_DATA, AL;

		mov AL, [a];
		out PIC1_DATA, AL;
		mov AL, [b];
		out PIC2_DATA, AL;
	}
}

/// lowest bit set = irq 0 enabled
void enableIrqs(ushort enabled) {
	enabled = ~enabled;
	asm {
		mov AX, enabled;
		out PIC1_DATA, AL;
		mov AL, AH;
		out PIC2_DATA, AL;
	}
}

align(1)
struct IdtEntry {
	align(1):
	ushort offsetLowWord;
	ushort selector;
	ubyte reserved;
	ubyte attributes;
	ushort offsetHighWord;
}

align(1)
struct DtLocation {
	align(1):
	ushort size;
	void* address;
}

static assert(DtLocation.sizeof == 6);

__gshared IdtEntry[256] idt;

void setInterruptHandler(ubyte number, void* handler) {
	IdtEntry entry;
	entry.offsetLowWord = cast(size_t)handler & 0xffff;
	entry.offsetHighWord = cast(size_t)handler >> 16;
	entry.attributes = 0x80 /* present */ |  0b1110 /* 32 bit interrupt gate */;
	entry.selector = 8;
	idt[number] = entry;
}

void loadIdt() {
	DtLocation loc;

	static assert(idt.sizeof == 8 * 256);

	loc.size = cast(ushort) (idt.sizeof - 1);
	loc.address = &idt;

	asm {
		lidt [loc];
	}
}


align(1)
struct GdtEntry {
	align(1):
	ushort limit;
	ushort baseLow;
	ubyte baseMiddle;
	ubyte access;
	ubyte limitAndFlags;
	ubyte baseHigh;
}

__gshared ubyte[0x64][4] tsses;
__gshared GdtEntry[3 + tsses.length] gdt;

void loadGdt() {
	GdtEntry entry;
	entry.limit = 0xffff;

	// page granularity and 32 bit
	entry.limitAndFlags = 0xc0 | 0x0f;
	entry.access = 0x9a; // present kernel code
	gdt[1] = entry;
	entry.access = 0x92; // data
	gdt[2] = entry;

	foreach(idx, ref tss; tsses) {
		auto tssPtr = cast(size_t) &tss;
		entry.baseLow = tssPtr & 0xffff;
		entry.baseMiddle = (tssPtr >> 16) & 0xff;
		entry.baseHigh = tssPtr >> 24;
		entry.limit = tss.sizeof;
		entry.limitAndFlags = 0x40; // present

		entry.access = 0x89; // ...idk
		gdt[3 + idx] = entry;
	}

	DtLocation loc;
	loc.size = cast(ushort) (gdt.sizeof - 1);
	loc.address = &gdt;

	asm {
		lgdt [loc];
	}
}
