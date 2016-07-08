
enum VBE_DISPI_IOPORT_INDEX = 0x01CE;
enum VBE_DISPI_IOPORT_DATA  = 0x01CF;
enum VBE_DISPI_INDEX_ID              = 0x0;
enum VBE_DISPI_INDEX_XRES            = 0x1;
enum VBE_DISPI_INDEX_YRES            = 0x2;
enum VBE_DISPI_INDEX_BPP             = 0x3;
enum VBE_DISPI_INDEX_ENABLE          = 0x4;
enum VBE_DISPI_INDEX_BANK            = 0x5;
enum VBE_DISPI_INDEX_VIRT_WIDTH      = 0x6;
enum VBE_DISPI_INDEX_VIRT_HEIGHT     = 0x7;
enum VBE_DISPI_INDEX_X_OFFSET        = 0x8;
enum VBE_DISPI_INDEX_Y_OFFSET        = 0x9;

enum VBE_DISPI_DISABLED              = 0x00;
enum VBE_DISPI_ENABLED               = 0x01;
enum VBE_DISPI_GETCAPS               = 0x02;
enum VBE_DISPI_8BIT_DAC              = 0x20;
enum VBE_DISPI_LFB_ENABLED           = 0x40;
enum VBE_DISPI_NOCLEARMEM            = 0x80;

void vbe_write(ushort index, ushort value)
{
	asm {
		mov AX, index;
		mov DX, VBE_DISPI_IOPORT_INDEX;
		out DX, AX;
		mov AX, value;
		mov DX, VBE_DISPI_IOPORT_DATA;
		out DX, AX;
	}
}


void vbe_set(ushort xres, ushort yres, ushort bpp) {
	vbe_write(VBE_DISPI_INDEX_ENABLE, VBE_DISPI_DISABLED);
	vbe_write(VBE_DISPI_INDEX_XRES, xres);
	vbe_write(VBE_DISPI_INDEX_YRES, yres);
	vbe_write(VBE_DISPI_INDEX_BPP, bpp);
	vbe_write(VBE_DISPI_INDEX_ENABLE, VBE_DISPI_ENABLED | VBE_DISPI_LFB_ENABLED);   
}

void example() {
	enum xres = 1280;
	enum yres = 1024;
	vbe_set(xres, yres, 32);

	// FIXME: this should be detected properly
	// http://forum.osdev.org/viewtopic.php?f=1&t=26038&start=30
	uint* omg = cast(uint*) 0xF000_0000;

	foreach(y; 0 .. yres)
	foreach(x; 0 .. xres) {
		//       xxRRGGBB
		*omg = 0x00ffff00;
		omg++;
	}
}
