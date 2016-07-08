module bare_metal.text_output;

version(bare_metal) {
	__gshared int lineLength = 80;
	__gshared char* video = cast(char*) 0xb8000;
}

void writeText(in char[] a) {
	const(char)* sptr = a.ptr;
	foreach(i; 0 .. a.length) {
		char c = *sptr;
		sptr++;
		if(c == '\n') {
			video += lineLength * 2;
			lineLength = 80;
		} else {
			*video = c;
			video++;
			*video = 10;
			video++;
			lineLength--;
			if(lineLength == 0)
				lineLength = 80;
		}
	}
}

