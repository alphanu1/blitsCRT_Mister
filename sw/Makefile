# blitscrtd -- GUD device daemon
#
# Native build for tests, cross build for the target:
#   make
#   make test
#   make CROSS_COMPILE=arm-linux-gnueabihf-

CROSS_COMPILE ?=
CC      := $(CROSS_COMPILE)gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=gnu11

# Daemon build number, printed at startup. Bumped whenever the daemon changes,
# so a log says which binary produced it. Same reason the kernel carries
# BLITSCRT_KREV: a fix that never reached the board is indistinguishable from a
# fix that did not work.
#
#   d1  bulk endpoint read in bounded chunks; BLITSCRT_TRACE; UDC bound by the
#       daemon once its descriptors are in
#   d2  bulk endpoint non-blocking -- wrong, a read is what queues the USB
#       request, so EAGAIN means the host can never deliver
#   d3  back to blocking chunked reads, heartbeat between chunks
#   d4  bulk endpoint on its own thread
#   d5  fabric access serialised between the two threads
#   d6  RGB888 no longer advertised -- the fetcher cannot read three bytes
#   d7  all four modes advertised again
#   d8  LZ4 offered and decompressed. 640x480i60 full-frame measured 51.98 fps
#       at 31.9 MB/s, so 1.2x clears 60 -- below the floor for sprite content
#   d9  one read per bulk transfer. Chunked reads made the kernel split the
#       request, leaving the remainder queued and desynchronising the stream
#   d10 accumulate across transfers. d9 read once and trusted the result, which
#       takes a fragment when a rect spans more than one -- "LZ4 block bad" at
#       every size. Ask for the whole buffer, accept short reads, loop
#   d11 word copies in the decompressor where a match cannot overlap, and a
#       per-frame breakdown of read/lz4/blit -- the wire is no longer the limit
#   d12 queue the rect headers. A single slot lost one when the host got a frame
#       ahead -- its pixels stayed on the wire and everything after decoded
#       against the wrong length
#   d13 LZ4 off by default while the desynchronisation was unexplained
#   d16 report achieved fps alongside the costs -- with the critical path well
#       inside the budget, a shortfall is the host, not this end
#   d15 the read overlaps the decompress and blit -- two threads and a two-slot
#       pool, so a frame costs max(read, lz4 + blit) rather than the sum
#   d14 read requests rounded to a packet boundary. Asking for exactly the
#       declared length makes the kernel split a padded transfer; asking for the
#       whole buffer swallows the frames behind it -- "read 1048576, header said
#       4741". Both end with the header and data out of step
#   d4  bulk endpoint on its own thread. A blocking read on the ep0 thread means
#       no control request can be answered while a frame arrives, and if the host
#       issues one during its flush both sides wait on each other -- which is
#       what the indefinite hang was
BLITSCRTD_BUILD ?= d18
CFLAGS  += -DBLITSCRTD_BUILD='"$(BLITSCRTD_BUILD)"'
# -lpthread: the bulk endpoint runs on its own thread, so a blocking read cannot
# stop ep0 being serviced. Static linking needs it named explicitly.
LDLIBS  ?= -lm -lpthread

# Link statically for the board. MiSTer's rootfs ships an older glibc than a
# modern cross toolchain builds against, so a dynamically linked daemon fails
# with "GLIBC_2.xx not found". A static binary carries its own libc and runs
# regardless. Set STATIC=0 for a normal dynamic build (e.g. host testing).
# Static. The board runs it (confirmed on hardware), and it carries its own libc
# so it does not depend on MiSTer's older glibc -- a dynamic build fails there
# with 'GLIBC_2.xx not found'. Set STATIC=0 for a dynamic build (host testing).
STATIC  ?= 1
ifeq ($(STATIC),1)
LDFLAGS ?= -static
else
LDFLAGS ?=
endif

CORE := device.c modes.c pll.c pll_reconfig.c fabric.c
OBJ  := lz4dec.o $(CORE:.c=.o) gadget.o main.o

.PHONY: all test clean

all: blitscrtd

blitscrtd: $(OBJ)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

# Bring-up helper: read/write fabric registers over the same transport. Reuses
# the daemon's fabric/pll objects so the gp path is identical.
blitscrt-ddrbench: ddrbench.o
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

blitscrt-peek: peek.o fabric.o pll_reconfig.o pll.o modes.o device.o
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

test: test_pll test_pll_reconfig test_modes test_device test_lz4
	@echo ""
	@./test_pll
	@echo ""
	@./test_pll_reconfig
	@echo ""
	@./test_modes
	@echo ""
	@./test_device
	@./test_lz4

test_pll: tests/test_pll.c pll.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

test_pll_reconfig: tests/test_pll_reconfig.c pll_reconfig.c pll.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

test_modes: tests/test_modes.c modes.c pll.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

test_lz4: tests/test_lz4.c lz4dec.c
	$(CC) $(CFLAGS) -o $@ tests/test_lz4.c lz4dec.c

test_device: tests/test_device.c $(CORE)
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

clean:
	rm -f *.o blitscrtd test_pll test_pll_reconfig test_modes test_device test_lz4
