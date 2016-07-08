extern(C) int tls = 0;
extern(C) int tls2 = 0;
__gshared gs = 0;

import bare_metal.textmode;

__gshared uint gotKey;
__gshared uint timerCount;
__gshared uint currentTask;

void timerHandler() {
	asm {
		naked;
		push EAX;
		mov EAX, [timerCount];
		inc EAX;
		mov [timerCount], EAX;

		mov AL, 0x20;
		out 0x20, AL;

		mov EAX, [currentTask];
		str AX;
		inc EAX;
		and EAX, 0b11;
		mov [currentTask], EAX;
	//	add AX, 3; // adjust to GDT entry
		ltr AX;

		pop EAX;
		iretd;
	}
}

void keyboardHandler() {
	asm {
		naked;
		push EAX;

		xor EAX, EAX;
		in AL, 0x60; // read the keyboard byte

		mov [gotKey], EAX;

		mov AL, 0x20;
		out 0x20, AL;

		pop EAX;
		iretd;
	}
}

void nullIh() {
	asm {
		naked;
		iretd;
	}
}

void initializeSystem() {
	import bare_metal.idt;

	loadGdt();
	mapPic();

	foreach(i; 0 .. 256)
		setInterruptHandler(cast(ubyte) i, &nullIh);

	setInterruptHandler(IRQOffset + 0, &timerHandler);
	setInterruptHandler(IRQOffset + 1, &keyboardHandler);
	loadIdt();

	enableIrqs(1 /* PIT */ |
		(1 << 1) /* IRQ1 enabled: keyboard */);

	asm {
		sti;
	}
}

void main() {
	if(bootInfo.flags & 0x01) {
		char[16] buffer;
		addText(intToString(bootInfo.mem_upper, buffer));
		addText( " KB memory available\n");
	}

	initializeSystem();

	asm {
		cli;
		/* fork */
		mov AX, 0;
		str AX; /* stores this state here */
	}

	addText("here");

	asm {
		mov EBX, [currentTask];
		or EBX, EBX;
		jnz new_task;
		inc [currentTask];
	}

	int count;
	char[16] buffer;
	while(1) {
		count++;
		asm {
			sti;
			hlt;
		}

		if(gotKey) {
			addText("Key event: ");
			addText(intToString(gotKey, buffer));
			addText("\n");
			gotKey = 0;
		}

		auto tc = intToString(timerCount, buffer);
		ubyte* b = cast(ubyte*) 0xb8000;
		b += (80 * 24 + 65) * 2; // bottom right of screen
		foreach(c; tc) {
			*b = c;
			b+=2;
		}


		tc = intToString(currentTask, buffer);
		b = cast(ubyte*) 0xb8000;
		b += (80 * 24 + 0) * 2; // bottom left of screen
		foreach(c; tc) {
			*b = c;
			b+=2;
		}

	}

	new_task:
	addText("fork!");
	asm {
		forever: hlt; jmp forever;
	}
}

/*
void main() {
	char* str = "hello".dup.ptr;

	gs = 10;
	asm {
		mov AX, DS;
		mov FS, AX;
		mov GS, AX;
	}

	tls = 10;
//	tls2 = 20;
}
*/

/+
// qemu -fda floppy.img -vga std
// mount -o loop floppy.img /mnt/image/ ; cp ~me/program/minimal-d/minimal /mnt/image/ ; umount /mnt/image

import memory;

void closureTest2(HeapClosure!(void delegate()) test) {
	write("\nptr is ", cast(size_t) test.ptr, "\n");
	test();

	auto b = test;
}

void closureTest() {
	string a = "whoa";
	scope(exit) write("\n\nexit\n\n");
	//throw new Exception("test");
	closureTest2( makeHeapClosure({ write(a); }) );
}

class Cool {
	string hey() { return "hey"; }

	int[] sl;
	void evil(scope int[] sl) {
		this.sl = sl;
	}
}

//@CustomInfo!("hey")
//@CustomInfo!(1)
class Beans: Cool {
	override string hey() { return "hey beans"; }
}

template arrlit(T...) {
	static __gshared immutable int[] literal = [T];
	alias arrlit = literal;
}

int main(string[] args) {
	if(args.length)
		write("Called as: ", args[0], "\n");
	if(args.length > 1)
		write("arg 1: ", args[1], "\n");
	if(environment.length)
		write("env: ", environment[0], "\n");

//return 0;
	/*
	write(typeid(immutable(char)[]).toString(), "\n");

	auto rtInfo = typeid(Beans).rtInfo();

	auto info = rtInfo.getCustomData!string;
	write("#1: ");
	if(info is null)
		write("<null>");
	else
		write(*info);
	write("\n");

	auto info2 = rtInfo.getCustomData!int;
	write("#2: ");
	if(info2 is null)
		write("<null>");
	else
		write(*info2);
	write("\n");

exit();
*/

	/*
	auto hash = rtInfo.hash;
	char[16] buffer;
	write(intToString(typehash!Beans, buffer));
	write("\ncool\n");
	write(intToString(hash, buffer));
	write("\n");
	write(rtInfo.stringOf);
	*/

	//args[1] = "whoa";
	auto arr = HeapArray!int(16);

	auto arr2 = arr.copy();

	arr2 ~= 10;
	write("trying literal\n");
	write(cast(size_t) arrlit!(1,2,3).ptr);
	arr2 ~= arrlit!(1,2,3);
	arr2 ~= arrlit!(1,2,3);
	write("success literal\n");

	auto arr3 = arr;

	write(arr2[0], "\n");

	write("just scroll moar\n");
	write("just scroll moar\n");

	Cool c = new Beans();
	scope(exit) manual_free(c);
	write(c.hey());
	write("\n");

	closureTest();
	throw new Exception("wtf");

	StackArray!(char, 250) a;
	a ~= environment[1];
	a ~= "\n";
	write(a);

	Beans beans = cast(Beans) c;
	if(beans !is null) {
		write(c.hey());
		write("\n");
		write("\n");
	}

	int foo = 10;
	switch(foo) {
		case 10:
			write("ten\n");
		default:
	}

	switch(a.slice) {
		case "test":
			write("cool");
		break;
		default:
			write("omg");
	}


/*
	foreach(arg; args)
		write(arg, "\n");
	foreach(arg; environment)
		write(arg, "\n");
*/
	return 0;
}
/+

// these comments are old
// I called this file minimal.d
// compile:
// dmd -c minimal.d -defaultlib=  ; gcc minimal.o -o minimal -g -m32 -nostdlib

// or if you want to use printf:
// dmd -c minimal.d -defaultlib=  ; gcc minimal.o -o minimal -g -m32 -nostdlib -lc

//module minimal;

struct InfoStruct {
	string info;
}

struct MoreRtInfo {
	string amazing;
}

struct small(T) if(T.sizeof < 9) {}

@CustomCheck!small
@CustomInfo!(InfoStruct("info struct data"))
class RTTest {
	static template userRtInfo(This) {
		static __gshared i = MoreRtInfo("amazingness");
		enum userRtInfo = &i;
	}
}

void main(){
	auto info = typeid(RTTest).rtInfo();
	if(info is null)
		throw new Exception("wtf");

	auto urtInfo = info.userRtInfo;
	if(urtInfo is null)
		write("urtInfo == null\n");
	else {
		auto urt = cast(immutable(MoreRtInfo)*) urtInfo;
		write("cool ",urt.amazing,"\n");
	}

	auto cd = info.getCustomInfo!InfoStruct;
	if(cd is null)
		write("InfoStruct is null\n");
	else
		write(cd.info, "\n");

	foreach(mi; ModuleInfo) {
		write("module: ", mi.name, "\n");
	}
}

static this() {
	write("hey\n");
}
+/
+/
