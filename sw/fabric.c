/* SPDX-License-Identifier: MIT */
/*
 * fabric.c -- register access over the HPS lightweight bridge.
 *
 * The bridge appears at 0xFF200000. Timing and PLL registers are staged and
 * latched together on a vblank, so a modeset never shows a partial frame at a
 * half-applied timing.
 */

#include "fabric.h"
#include "blitscrt_regs.h"

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <errno.h>

/*
 * Two transports behind one interface. LWH2F maps the register span directly;
 * GP marshals each access as a command word to the h2f general-purpose port and
 * a response word back, matching rtl/blitscrt_bridge.v BRIDGE="GP".
 *
 * The bridge moves 16 data bits per command, so a 32-bit write is two commands:
 * low half, then high half with both mode bits set.
 */
enum fabric_transport { XPORT_LWH2F, XPORT_GP };

struct blitscrt_fabric {
	int      fd;
	enum fabric_transport xport;
	volatile uint8_t *base;             /* LWH2F: the register span */
	volatile uint32_t *gp_out;          /* GP: ARM -> fabric command */
	volatile uint32_t *gp_in;           /* GP: fabric -> ARM response */
	size_t   span;
	int      strobe;                    /* GP: toggles each command */
};

/* GP command word layout, mirroring blitscrt_bridge.v */
#define GP_STROBE   (1u << 31)
#define GP_WRITE    (1u << 30)
#define GP_ADDR_SH  16
#define GP_ADDR_MASK 0x3fffu

/* The HPS h2f general-purpose registers live in the FPGA-manager address
 * window. gp_out is written by the ARM, gp_in read back. */
#define GP_H2F_BASE  0xFF706000u        /* fpgamgr gpo/gpi on Cyclone V */
#define GP_GPO_OFF   0x10u
#define GP_GPI_OFF   0x14u

/* Reset manager brgmodrst: clearing a bit takes that bridge out of reset. */
#define RSTMGR_BRGMODRST 0xFFD0501Cu   /* [0]=hps2fpga [1]=lwhps2fpga [2]=fpga2hps */

static void bridge_enable(int memfd)
{
	long page = sysconf(_SC_PAGESIZE);
	off_t aligned = (off_t)RSTMGR_BRGMODRST & ~(off_t)(page - 1);
	unsigned off = (unsigned)((off_t)RSTMGR_BRGMODRST - aligned);
	volatile unsigned char *map;
	volatile uint32_t *reg;
	uint32_t before, after;

	map = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_SHARED, memfd, aligned);
	if (map == MAP_FAILED) {
		fprintf(stderr, "blitscrt: bridge_enable mmap failed (%s)\n", strerror(errno));
		return;
	}
	reg = (volatile uint32_t *)(map + off);
	before = *reg;
	/* Clear the low three bits: release all three HPS<->FPGA bridges. */
	*reg &= ~0x7u;
	after = *reg;
	fprintf(stderr, "blitscrt: brgmodrst 0x%08x -> 0x%08x\n", before, after);
	munmap((void *)map, page);
}

struct blitscrt_fabric *blitscrt_fabric_open(void)
{
	struct blitscrt_fabric *f;
	long page = sysconf(_SC_PAGESIZE);
	off_t aligned;

	f = calloc(1, sizeof *f);
	if (!f)
		return NULL;

	f->fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (f->fd < 0) {
		free(f);
		return NULL;
	}

	/*
	 * Bring the HPS-to-FPGA bridges out of reset. When MiSTer boots its own
	 * Linux (not through our u-boot override, which does 'bridge enable'),
	 * the bridges can be held in reset -- reads of the fabric window then
	 * return zeros and the ID check below fails for no obvious reason. Clear
	 * the reset bits in the reset manager's brgmodrst register so the gp port
	 * reaches the fabric. Harmless if they are already out of reset.
	 */
	bridge_enable(f->fd);

	/*
	 * GP transport: the fabric is reached through the h2f general-purpose
	 * port, matching BRIDGE="GP" in the RTL. This is the default because it
	 * is the interface MiSTer proves on this board with no extra HPS blocks.
	 * Set BLITSCRT_LWH2F in the environment to use the lightweight bridge
	 * instead, once that primitive is instantiated.
	 */
	f->xport = getenv("BLITSCRT_LWH2F") ? XPORT_LWH2F : XPORT_GP;

	if (f->xport == XPORT_LWH2F) {
		aligned = BLITSCRT_LWBRIDGE_BASE & ~(off_t)(page - 1);
		f->span = BLITSCRT_REG_SPAN + (BLITSCRT_LWBRIDGE_BASE - aligned);
		f->base = mmap(NULL, f->span, PROT_READ | PROT_WRITE,
			       MAP_SHARED, f->fd, aligned);
		if (f->base == MAP_FAILED) {
			close(f->fd); free(f); return NULL;
		}
		f->base += (BLITSCRT_LWBRIDGE_BASE - aligned);
	} else {
		off_t a = GP_H2F_BASE & ~(off_t)(page - 1);
		f->span = 0x1000 + (GP_H2F_BASE - a);
		f->base = mmap(NULL, f->span, PROT_READ | PROT_WRITE,
			       MAP_SHARED, f->fd, a);
		if (f->base == MAP_FAILED) {
			close(f->fd); free(f); return NULL;
		}
		f->gp_out = (volatile uint32_t *)
			(f->base + (GP_H2F_BASE - a) + GP_GPO_OFF);
		f->gp_in  = (volatile uint32_t *)
			(f->base + (GP_H2F_BASE - a) + GP_GPI_OFF);
	}

	{
		uint32_t id = blitscrt_fabric_read(f, BLITSCRT_REG_ID);
		if (id != BLITSCRT_ID_MAGIC) {
			fprintf(stderr, "blitscrt: no ID magic on %s: read 0x%08x, want 0x%08x\n",
				f->xport == XPORT_GP ? "gp" : "lwh2f",
				id, BLITSCRT_ID_MAGIC);
			if (f->xport == XPORT_GP) {
				uint32_t gi = *f->gp_in;
				fprintf(stderr, "blitscrt: raw gp_in=0x%08x gp_out=0x%08x\n",
					gi, *f->gp_out);
				/* Our current RTL forces gp_in[30:16] to zero. If those bits
				 * are set, the fabric is an OLD bitstream (pre-handshake-fix)
				 * -- the .rbf on the card needs rebuilding and reflashing. */
				if (gi & 0x7fff0000u)
					fprintf(stderr, "blitscrt: gp_in[30:16] nonzero -> OLD bitstream, reflash the .rbf\n");
			}
			/* Probe a few registers raw, so we can see if ANY read lands. */
			fprintf(stderr, "blitscrt: probe id=0x%08x ver=0x%08x status=0x%08x\n",
				blitscrt_fabric_read(f, BLITSCRT_REG_ID),
				blitscrt_fabric_read(f, BLITSCRT_REG_VERSION),
				blitscrt_fabric_read(f, BLITSCRT_REG_STATUS));
			fprintf(stderr, "blitscrt: (0x00000000 = bridge down or core not loaded; "
				"other = protocol or base mismatch)\n");
			blitscrt_fabric_close(f);
			return NULL;
		}
	}
	return f;
}

void blitscrt_fabric_close(struct blitscrt_fabric *f)
{
	if (!f) return;
	if (f->base) munmap((void *)((uintptr_t)f->base & ~(uintptr_t)(sysconf(_SC_PAGESIZE)-1)), f->span);
	if (f->fd >= 0) close(f->fd);
	free(f);
}

/* GP: send one command and, for a read, spin for the strobe echo. */
static uint32_t gp_command(struct blitscrt_fabric *f, int wr,
			   uint32_t addr, uint16_t data)
{
	uint32_t cmd;
	int spin;

	/* Toggle the strobe for this command, then build the word carrying that
	 * new strobe. The fabric echoes this same strobe back in gp_in[31] only
	 * once the transaction has completed (see blitscrt_bridge.v), so we wait
	 * for the echo to match the strobe we just sent -- for both reads and
	 * writes, so a write is known to have landed before the next command. */
	/*
	 * SAFETY: on MiSTer, gp_out[31:30] is core reset control (resetd <=
	 * gp_out[31:30] in sys_top.v), and gp_out[20:17] are chip-select/clock.
	 * Our strobe/address scheme collides with those, so driving gp_out here can
	 * poke the core reset and never actually addresses our register block. The
	 * gp transport is known-broken on MiSTer (see docs/GP_FINDINGS.md); until it
	 * is redesigned around MiSTer's io protocol or replaced with f2sdram, do not
	 * drive gp_out unless explicitly opted in for bring-up experiments.
	 */
	if (!getenv("BLITSCRT_GP_UNSAFE"))
		return 0;
	f->strobe ^= 1;
	cmd = (f->strobe ? GP_STROBE : 0) |
	      (wr ? GP_WRITE : 0) |
	      ((addr & GP_ADDR_MASK) << GP_ADDR_SH) | data;
	*f->gp_out = cmd;

	for (spin = 0; spin < 100000; spin++) {
		uint32_t r = *f->gp_in;
		if (((r >> 31) & 1) == (unsigned)f->strobe)
			return r & 0xffff;
	}
	return 0;   /* timed out waiting for the fabric to complete */
}

uint32_t blitscrt_fabric_read(struct blitscrt_fabric *f, uint32_t off)
{
	if (f->xport == XPORT_LWH2F)
		return *(volatile uint32_t *)(f->base + off);
	/* GP moves 16 bits per command; assemble a word from two reads. */
	{
		uint32_t lo = gp_command(f, 0, off, 0);
		uint32_t hi = gp_command(f, 0, off | 0x1, 0);   /* high-half select */
		return (hi << 16) | lo;
	}
}

void blitscrt_fabric_write(struct blitscrt_fabric *f, uint32_t off, uint32_t v)
{
	if (f->xport == XPORT_LWH2F) {
		*(volatile uint32_t *)(f->base + off) = v;
		return;
	}
	gp_command(f, 1, off, v & 0xffff);
	if (v >> 16)
		gp_command(f, 1, off | 0x1, v >> 16);
}

int blitscrt_fabric_pll_reconfig(struct blitscrt_fabric *f,
				 const struct pll_config *p)
{
	struct pll_reconfig_seq q;
	unsigned int i;
	int spin;

	if (!f || !p)
		return -1;
	if (pll_reconfig_build(p, 0, &q) < 0)
		return -1;

	for (i = 0; i < q.count; i++)
		blitscrt_fabric_write(f, BLITSCRT_PLLRECFG_OFFSET +
					 (q.w[i].addr * 4), q.w[i].data);

	/* Busy clears when the counters are shifted in, lock returns some
	 * microseconds later. The pixel clock is unusable in between, which is
	 * why the caller holds the video pipeline in reset. */
	for (spin = 0; spin < 1000000; spin++) {
		uint32_t st = blitscrt_fabric_read(f, BLITSCRT_PLLRECFG_OFFSET +
						      (PLL_RECONFIG_STATUS * 4));
		if (!(st & PLL_STATUS_BUSY) && (st & PLL_STATUS_LOCKED))
			return 0;
	}
	return -1;
}

int blitscrt_fabric_set_mode(struct blitscrt_fabric *f,
			     const struct blitscrt_timing *t, uint8_t format)
{
	uint32_t fmt = BLITSCRT_FMT_RGB565;
	int spin;

	if (!f || !t) return -1;

	switch (format) {
	case 0x50: fmt = BLITSCRT_FMT_RGB888; break;   /* 3 bytes, full ladder */
	case 0x30: fmt = BLITSCRT_FMT_RGB332; break;   /* 1 byte */
	default:   fmt = BLITSCRT_FMT_RGB565; break;   /* 2 bytes */
	}

	blitscrt_fabric_write(f, BLITSCRT_REG_H_SY,  t->h_sy);
	blitscrt_fabric_write(f, BLITSCRT_REG_H_BP,  t->h_bp);
	blitscrt_fabric_write(f, BLITSCRT_REG_H_ACT, t->h_act);
	blitscrt_fabric_write(f, BLITSCRT_REG_H_FP,  t->h_fp);
	blitscrt_fabric_write(f, BLITSCRT_REG_V_SY,  t->v_sy);
	blitscrt_fabric_write(f, BLITSCRT_REG_V_BP,  t->v_bp);
	blitscrt_fabric_write(f, BLITSCRT_REG_V_ACT, t->v_act);
	blitscrt_fabric_write(f, BLITSCRT_REG_V_FP,  t->v_fp);
	blitscrt_fabric_write(f, BLITSCRT_REG_MODE_FLAGS, t->mode_flags);

	blitscrt_fabric_write(f, BLITSCRT_REG_PLL_M, t->pll.m);
	blitscrt_fabric_write(f, BLITSCRT_REG_PLL_N, t->pll.n);
	blitscrt_fabric_write(f, BLITSCRT_REG_PLL_C, t->pll.c);

	/* Reprogram the clock before latching the timing that assumes it. */
	if (blitscrt_fabric_pll_reconfig(f, &t->pll) < 0)
		return -1;
	blitscrt_fabric_write(f, BLITSCRT_REG_PCLK_KHZ,
			      (uint32_t)(t->pll.actual_hz / 1000));

	blitscrt_fabric_write(f, BLITSCRT_REG_FB_FORMAT, fmt);
	blitscrt_fabric_write(f, BLITSCRT_REG_FB_STRIDE,
			      t->h_act * (fmt == BLITSCRT_FMT_RGB332 ? 1 :
					  fmt == BLITSCRT_FMT_RGB888 ? 3 : 2));

	/* latch everything together on the next vblank */
	blitscrt_fabric_write(f, BLITSCRT_REG_APPLY, 1);

	for (spin = 0; spin < 100000; spin++) {
		if (!(blitscrt_fabric_read(f, BLITSCRT_REG_STATUS) &
		      BLITSCRT_STAT_APPLYING))
			return 0;
	}
	return -1;      /* no vblank came; scanout is stopped or the PLL is lost */
}

void blitscrt_fabric_enable(struct blitscrt_fabric *f, int on)
{
	uint32_t c;
	if (!f) return;
	c = blitscrt_fabric_read(f, BLITSCRT_REG_CTRL);
	if (on) c |=  BLITSCRT_CTRL_ENABLE;
	else    c &= ~BLITSCRT_CTRL_ENABLE;
	/* the test card is what shows when scanout is off */
	if (on) c &= ~BLITSCRT_CTRL_TESTCARD;
	else    c |=  BLITSCRT_CTRL_TESTCARD;
	blitscrt_fabric_write(f, BLITSCRT_REG_CTRL, c);
}

void blitscrt_fabric_overlay_clear(struct blitscrt_fabric *f)
{
	unsigned r, c;
	if (!f) return;
	/* Clear the three mode banks (rows 0..47). The overlay shows whichever mode
	 * bank the front-panel button (cur_mode) has selected, so the live text has
	 * to land in all three; clearing them first wipes the baked "NO HPS YET"
	 * idle banners. Bank 3 (rows 48..63, the daemon-not-running screen) is left
	 * baked. Byte-addressed: char (r,c) is at OFFSET + r*COLS + c. */
	for (r = 0; r < 3 * BLITSCRT_CHARRAM_BANK_ROWS; r++)
		for (c = 0; c < BLITSCRT_CHARRAM_COLS; c++)
			blitscrt_fabric_write(f,
				BLITSCRT_CHARRAM_OFFSET +
				(r * BLITSCRT_CHARRAM_COLS + c),
				BLITSCRT_CHAR_BLANK);
}

void blitscrt_fabric_overlay_line(struct blitscrt_fabric *f,
				  unsigned row, unsigned col, const char *s)
{
	unsigned i, b;
	if (!f || row >= BLITSCRT_CHARRAM_BANK_ROWS) return;   /* row is within a bank */
	for (i = 0; s[i] && col + i < BLITSCRT_CHARRAM_COLS; i++) {
		uint8_t ch = (uint8_t)s[i];
		if (ch == ' ') ch = BLITSCRT_CHAR_BACKED;
		/* Replicate into all three mode banks so the line shows whichever the
		 * button has selected. Bank b, row `row` is at (b*16 + row). */
		for (b = 0; b < 3; b++)
			blitscrt_fabric_write(f,
				BLITSCRT_CHARRAM_OFFSET +
				(((b * BLITSCRT_CHARRAM_BANK_ROWS + row) *
				  BLITSCRT_CHARRAM_COLS) + col + i),
				ch & 0x7F);
	}
}
