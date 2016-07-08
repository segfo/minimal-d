module bare_metal.textmode;

// http://wiki.osdev.org/Detecting_Memory_%28x86%29#Memory_Map_Via_GRUB
// http://wiki.osdev.org/Memory_Map_%28x86%29#BIOS_Data_Area_.28BDA.29
enum fullLineLength = 80;
enum fullTextHeight = 25;
enum videoMemory = 0xb8000;
__gshared int lineLength = fullLineLength;
__gshared int linesRemaining = fullTextHeight;
__gshared char* video = cast(char*) videoMemory;

void cls() {
	video = cast(char*) videoMemory;
	lineLength = fullLineLength;
	linesRemaining = fullTextHeight;

	auto vlol = video;
	foreach(i; 0 .. fullLineLength * fullTextHeight) {
		*vlol = ' ';
		vlol++;
//		*vlol = ; FIXME reset color
		vlol++;
	}
}

void addText(in void[] txt) {
	auto slen = txt.length;
	auto sptr = txt.ptr;
	foreach(i; 0 .. slen) {
		char c = * cast(char*) sptr;
		sptr++;
		if(c == '\n') {
			video += lineLength * 2;
			linesRemaining--;
			lineLength = fullLineLength;
			checkAndDoVideoScroll();
		} else {
			*video = c;
			video++;
			*video = 10;
			video++;
			lineLength--;
			if(lineLength == 0) {
				lineLength = fullLineLength;
				linesRemaining--;
				checkAndDoVideoScroll();
			}
		}
	}

}

void checkAndDoVideoScroll() {
	if(linesRemaining < 0) {
		linesRemaining = 0;
		video = cast(char*) videoMemory;

		foreach(i; 0 .. fullTextHeight - 1) {
			foreach(i2; 0 .. 80 * 2) {
				*video = *(video + (80 * 2));
				video++;
			}
		}

		foreach(i; 0 .. fullLineLength) {
			video[i*2] = ' ';
			// video[i*2+1] = FIXME reset color;
		}
	}

	updateCursor();
}

void updateCursor() {
	moveCursor(cast(ubyte) (fullLineLength - lineLength), cast(ubyte) (fullTextHeight - linesRemaining));
}

void moveCursor(ubyte x, ubyte y) {
	ushort position = (y * 80) + x;
	ubyte posHigh = (position >> 8) & 0xff;
	ubyte posLow = position & 0xff;
	asm {
		mov EAX, 0x0463;
		mov DX, [EAX]; // read the video port number from BIOS memory
		mov AL, 0x0E;
		out DX, AL;
		inc DX;
		mov AL, posHigh;
		out DX, AL;
		dec DX;
		mov AL, 0x0F;
		out DX, AL;
		inc DX;
		mov AL, posLow;
		out DX, AL;
	}
}

