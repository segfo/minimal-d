BITS=32

ifeq ($(LIBC),yes)
LIBCDMD=-version=with_libc
LIBCGCC=
else
LIBCDMD=
LIBCGCC=-nostdlib # -T minfo.ld
endif

all:
	# gcc -m$(BITS) -c -D HAVE_MMAP=0 -D LACKS_UNISTD_H -D LACKS_TIME_H -D NO_MALLOC_STATS malloc.c

	# dmd -betterC
	dmd -debug=allocations -m$(BITS) -debug -c object.d minimal.d invariant.d memory.d -gc -defaultlib= -debuglib= $(LIBCDMD) -version=bare_metal bare_metal/*.d
	#dmd -version=with_libc -debug=allocations -m$(BITS) -debug -c object.d minimal.d invariant.d memory.d -gc -defaultlib= -debuglib= $(LIBCDMD)
	gcc *.o bare_metal/*.o -o minimal -g -m$(BITS) $(LIBCGCC) # malloc.o

	# nm -t d -l -S --size-sort minimal | ~/demangle
