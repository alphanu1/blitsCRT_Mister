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
#   d18 LZ4 on by default in the daemon itself, not set by init
#   d28 refuse modes wider than the scanout line buffer, which the fabric now
#       reports. A 1280 mode on a 1024 buffer scans out wrapped lines
#   d27 five more modes: true PAL 720x576i50, and 1280-wide super-resolution at
#       240p60, 480i60, 288p50 and 576i50. h_max raised to 1280
#   d26 doubling copy in the decompressor. Small offsets -- a repeated pixel or
#       pixel pair, most of sprite data -- used a byte loop; now every copy is
#       memcpy and the gap doubles. 1.37x on x86, more expected on the A9
#   d25 report the running mode on every fps line -- peek cannot read it while
#       the daemon runs, and stopping the daemon clears HPS_TIMING
#   d24 split the bulk read into waiting and transferring, and report the rate
#       while bytes are moving -- a slow link and a slow host look the same in
#       the total and are different problems
#   d23 BLITSCRT_EDID=name sends the name descriptor alone, without the range
#       limits -- the half a host was seen to act on
#   d22 EDID off by default -- a host given one picks a mode wider than the
#       raster and drops frames, even with no timings in the block
#   d21 blitscrt-peek links $(CORE) instead of a hand-written object list, so a
#       new core file reaches every target rather than just the daemon
#   d20 an EDID with a monitor name and the sync range, so a host stops calling
#       this "VGA-1-unknown". No timings in it -- the mode list is authoritative
#   d19 a greppable build tag in the binary, and main.o depends on the Makefile
#       so bumping the number cannot leave a stale object behind
#   d34 withdrew 1280x480i60, 1280x576i50 and 1280x288p50 -- 73.7 MB/s against
#       a link carrying 35, so they could not hold a frame
#   d35 one advertised mode, 642x480i60. 642 rather than 640 so a Switchres
#       modeline cannot be confused with the fallback in a list or a log
#   d36 648x480i60 rather than 642: the stride must be a whole number of 8-byte
#       beats or every line starts at a different byte and the picture shears.
#       An unaligned width is now refused rather than advertised
#   d37 scanout stride padded to a whole f2sdram beat, so any width works --
#       a Switchres modeline never passes through the advertised list
#   d38 TEMPORARY: 642x480i60 advertised alongside 648 to prove the stride
#       padding on hardware. Remove once tested
#   d39 stride padding proven on hardware -- 642 and 648 both stable -- and the
#       temporary 642x480i60 test mode removed
#   d40 stale comments corrected: the apply handshake is fixed rather than
#       worked around, and mode counts followed the list down to one
#   d41 the user button toggles the USB connection: unbind the UDC so the host
#       sees an orderly detach, and stay disconnected until pressed again
BLITSCRTD_BUILD ?= d42
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

CORE := edid.c device.c modes.c pll.c pll_reconfig.c fabric.c
OBJ  := lz4dec.o $(CORE:.c=.o) gadget.o main.o

.PHONY: all test clean

all: blitscrtd

blitscrtd: $(OBJ)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

# Bring-up helper: read/write fabric registers over the same transport. Reuses
# the daemon's fabric/pll objects so the gp path is identical.
blitscrt-ddrbench: ddrbench.o
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $^

# $(CORE) rather than a hand-written list: peek links the same core objects the
# daemon does, so adding a file to CORE reaches both. Spelling them out here
# meant edid.c was added in one place and the tool failed to link in another.
blitscrt-peek: peek.o $(CORE:.c=.o)
	$(CC) $(LDFLAGS) -o $@ $^ $(LDLIBS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

test: test_pll test_pll_reconfig test_modes test_device test_lz4 test_edid \
      test_stride
	@echo ""
	@./test_pll
	@echo ""
	@./test_pll_reconfig
	@echo ""
	@./test_modes
	@echo ""
	@./test_device
	@./test_lz4
	@./test_edid
	@echo
	@./test_stride

test_pll: tests/test_pll.c pll.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

test_pll_reconfig: tests/test_pll_reconfig.c pll_reconfig.c pll.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

test_modes: tests/test_modes.c modes.c pll.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

# main.o carries BLITSCRTD_BUILD, and make does not track CFLAGS changes -- so
# bumping the build number alone would leave the old object in place and the
# binary would report a version it is not. Depend on the Makefile so it cannot.
main.o: Makefile

test_stride: tests/test_stride.c
	$(CC) $(CFLAGS) -I. -o $@ $<

test_edid: tests/test_edid.c edid.c
	$(CC) $(CFLAGS) -o $@ tests/test_edid.c edid.c

test_lz4: tests/test_lz4.c lz4dec.c
	$(CC) $(CFLAGS) -o $@ tests/test_lz4.c lz4dec.c

test_device: tests/test_device.c $(CORE)
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

clean:
	rm -f *.o blitscrtd test_pll test_pll_reconfig test_modes test_device test_lz4
