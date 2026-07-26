# blitscrtd -- GUD device daemon
#
# Native build for tests, cross build for the target:
#   make
#   make test
#   make CROSS_COMPILE=arm-linux-gnueabihf-

CROSS_COMPILE ?=
CC      := $(CROSS_COMPILE)gcc
CFLAGS  ?= -O2 -Wall -Wextra -std=gnu11
LDLIBS  ?= -lm

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
OBJ  := $(CORE:.c=.o) gadget.o main.o

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

test: test_pll test_pll_reconfig test_modes test_device
	@echo ""
	@./test_pll
	@echo ""
	@./test_pll_reconfig
	@echo ""
	@./test_modes
	@echo ""
	@./test_device

test_pll: tests/test_pll.c pll.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

test_pll_reconfig: tests/test_pll_reconfig.c pll_reconfig.c pll.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

test_modes: tests/test_modes.c modes.c pll.c
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

test_device: tests/test_device.c $(CORE)
	$(CC) $(CFLAGS) -o $@ $^ $(LDLIBS)

clean:
	rm -f *.o blitscrtd test_pll test_pll_reconfig test_modes test_device
