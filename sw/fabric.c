/* SPDX-License-Identifier: GPL-2.0-or-later */
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
#include <time.h>
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
	void   (*tick_fn)(void *);          /* fed during long waits */
	void    *tick_arg;
	int      fd;
	enum fabric_transport xport;
	volatile uint8_t *base;             /* LWH2F: the register span */
	volatile uint32_t *gp_out;          /* GP: ARM -> fabric command */
	volatile uint32_t *gp_in;           /* GP: fabric -> ARM response */
	size_t   span;
	int      strobe;                    /* GP: toggles each command */
	unsigned sc_w, sc_h;                /* scanout geometry, read at open */
	uint32_t caps;                      /* BLITSCRT_CAP_*, read at open */

	/* DDR3 scanout only: the reserved window, mapped uncached. */
	volatile uint8_t *sc_win;
	size_t   sc_win_span;
	uint32_t sc_phys;
	unsigned sc_bpp, sc_stride;
};

static int map_scanout_window(struct blitscrt_fabric *f)
{
	if (f->sc_win)
		return 0;
	f->sc_phys = BLITSCRT_SCANOUT_DDR_BASE;
	f->sc_win_span = BLITSCRT_SCANOUT_DDR_SIZE;
	f->sc_win = mmap(NULL, f->sc_win_span, PROT_READ | PROT_WRITE,
			 MAP_SHARED, f->fd, (off_t)f->sc_phys);
	if (f->sc_win == MAP_FAILED) {
		f->sc_win = NULL;
		fprintf(stderr, "blitscrt: cannot map scanout window at 0x%08x "
				"(%s) -- is mem= reserving it?\n",
			BLITSCRT_SCANOUT_DDR_BASE, strerror(errno));
		return -1;
	}
	return 0;
}

static unsigned fmt_bpp(uint32_t fmt)
{
	switch (fmt) {
	case BLITSCRT_FMT_RGB332:   return 1;
	case BLITSCRT_FMT_RGB888:   return 3;
	case BLITSCRT_FMT_XRGB8888: return 4;
	default:                    return 2;   /* RGB565 */
	}
}

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

		/*
		 * Resynchronise the strobe to whatever the fabric last saw.
		 *
		 * The strobe is an edge, and the fabric holds its parity in a
		 * register that outlives this process. f->strobe starts at zero
		 * in every fresh one, so if the last program to touch gp
		 * finished on an odd command count, our first command carries
		 * the parity the fabric already has: no edge, no transaction.
		 * gp_in[31] is still echoing that parity from before, so the
		 * spin in gp_command() matches instantly and hands back the
		 * readdata left in the bridge by the *previous process*.
		 *
		 * That is why it looked intermittent -- whether it bites depends
		 * on whether the last invocation issued an odd or even number of
		 * commands. No testbench could have found it: the RTL is correct
		 * and the state that was wrong is ours.
		 */
		if (getenv("BLITSCRT_GP_UNSAFE"))
			f->strobe = (int)((*f->gp_in >> 31) & 1);
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

	/* Scanout geometry is whatever memory is fitted -- a compile-time
	 * parameter on-chip, something else once it moves off. Read it rather
	 * than assume it. A fabric older than 3.0 has no such register and
	 * answers zero, which leaves the rect calls refusing rather than
	 * scribbling at a guessed pitch. */
	{
		uint32_t g = blitscrt_fabric_read(f, BLITSCRT_REG_SCANOUT_GEOM);
		f->sc_w = g & 0xffffu;
		f->sc_h = (g >> 16) & 0xffffu;
		/*
		 * Version gates, and they are not all advisory.
		 *
		 * 3.2 added CAPS, SCANOUT_DIAG and a writable SCANOUT_GEOM. An
		 * undecoded offset reads back zero, which is the same value a
		 * dropped parameter gives, so an older fabric needs saying out
		 * loud rather than leaving the caller to infer it.
		 *
		 * 3.4 added LIVE_*, and that one is a hard dependency:
		 * set_mode() confirms a modeset by reading the raster back
		 * rather than trusting STAT_APPLYING. Below 3.4 those registers read
		 * zero, the confirmation can never succeed, and every modeset
		 * fails however well it actually went.
		 */
		uint32_t ver = blitscrt_fabric_read(f, BLITSCRT_REG_VERSION);
		if (ver < 0x00030004u)
			fprintf(stderr,
				"blitscrt: fabric %u.%u is too old for this daemon "
				"(needs 3.4)\n"
				"  modesets will fail: set_mode confirms against "
				"LIVE_*, which reads zero here\n",
				ver >> 16, ver & 0xffffu);
		else if (ver < 0x00030008u)
			fprintf(stderr,
				"blitscrt: fabric %u.%u; 3.8 fixes PLL reconfig "
				"reads, so modes needing a clock the fabric was "
				"not compiled with will fail\n",
				ver >> 16, ver & 0xffffu);

		/* Read twice and require agreement. This is cached for the life of
		 * the handle and every write path keys off it, so a single bad
		 * read here silently routes rects at the wrong memory for the
		 * whole session with no further symptom. */
		f->caps = blitscrt_fabric_read(f, BLITSCRT_REG_CAPS);
		if (f->caps != blitscrt_fabric_read(f, BLITSCRT_REG_CAPS)) {
			fprintf(stderr, "blitscrt: CAPS read unstable; re-reading\n");
			f->caps = blitscrt_fabric_read(f, BLITSCRT_REG_CAPS);
		}

		/* Take the rest of the scanout state from the fabric too, rather
		 * than assuming RGB565 and a packed stride. Whatever configured
		 * it last may have been a different process entirely -- every
		 * blitscrt-peek invocation is one -- and the fabric is the only
		 * thing that remembers. */
		f->sc_bpp    = fmt_bpp(blitscrt_fabric_read(f,
					BLITSCRT_REG_SCANOUT_FORMAT) & 0x7u);
		f->sc_stride = blitscrt_fabric_read(f, BLITSCRT_REG_SCANOUT_STRIDE);
		if (!f->sc_stride)
			f->sc_stride = f->sc_w * f->sc_bpp;

		/* Map the window here, not in configure(). It is a property of
		 * the fabric reporting DDR3, not of having just set geometry --
		 * and a short-lived tool that only wants to blit never calls
		 * configure at all. */
		if (f->caps & BLITSCRT_CAP_SCANOUT_DDR3)
			(void)map_scanout_window(f);
		if (!f->sc_w || !f->sc_h)
			fprintf(stderr, "blitscrt: fabric reports no scanout "
					"geometry (needs fabric 3.0); rect "
					"writes disabled\n");
	}
	return f;
}

void blitscrt_fabric_close(struct blitscrt_fabric *f)
{
	if (!f) return;
	if (f->sc_win) munmap((void *)f->sc_win, f->sc_win_span);
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

/*
 * One command, always. blitscrt_fabric_write() happens to skip the high half
 * when the value fits in 16 bits, but that is an optimisation of the value, not
 * a property of the call, and the per-pixel cost of the rect path is worth
 * being explicit about: one gp command per pixel is the floor this transport
 * allows, and this is the call that hits it.
 */
void blitscrt_fabric_write16(struct blitscrt_fabric *f, uint32_t off, uint16_t v)
{
	if (!f) return;
	if (f->xport == XPORT_LWH2F) {
		*(volatile uint32_t *)(f->base + off) = v;
		return;
	}
	gp_command(f, 1, off, v);
}

uint32_t blitscrt_fabric_caps(struct blitscrt_fabric *f)
{
	return f ? f->caps : 0;
}

/*
 * Tell the fabric how big the picture is and where it lives, and on a DDR3
 * build map the window the daemon writes into.
 *
 * The window is uncached, which it has to be: f2sdram reaches the SDRAM
 * controller directly and is not coherent with the A9's caches, so anything
 * left sitting in L2 would simply not be there when the fetcher looked. That
 * costs read bandwidth and almost nothing on writes -- measured at 110 MB/s by
 * memcpy against 69 MB/s for hand-rolled stores, which is why every path below
 * copies whole rows rather than looping over pixels.
 *
 * Geometry, stride, base and format are staged and latch together on a vblank,
 * so this cannot leave the fetcher reading a new width at an old stride.
 */
int blitscrt_scanout_configure(struct blitscrt_fabric *f,
			       unsigned w, unsigned h, uint32_t format)
{
	unsigned bpp;

	if (!f || !w || !h) return -1;
	bpp = fmt_bpp(format);

	f->sc_w = w;
	f->sc_h = h;
	f->sc_bpp = bpp;

	/*
	 * Stride padded up to a whole f2sdram beat, which is why it is not
	 * simply w * bpp.
	 *
	 * The port is 64 bits wide and Avalon reads are word-addressed, so the
	 * fetcher cannot read a beat from an unaligned byte address. Line n sits
	 * at base + n * stride, and that only lands on a beat boundary if the
	 * stride is a multiple of eight. With 642 pixels at 16bpp -- 1284 bytes,
	 * 160.5 beats -- every line began at a different byte within a beat and
	 * the picture sheared a little further across on each successive line.
	 *
	 * Padding fixes it for any width, which matters because a Switchres
	 * modeline can ask for anything and does not go through the advertised
	 * list. The few spare bytes at the end of each line are never fetched:
	 * the fetcher reads sc_w * bpp bytes and the scanout bounds x against
	 * sc_w, so they are neither read nor displayed. They cost a little
	 * memory in a 32 MB window and nothing else.
	 */
	f->sc_stride = (w * bpp + BLITSCRT_F2SDRAM_BEAT - 1u) &
		       ~(BLITSCRT_F2SDRAM_BEAT - 1u);

	if (f->caps & BLITSCRT_CAP_SCANOUT_DDR3) {
		size_t need = (size_t)f->sc_stride * h;

		if (need > BLITSCRT_SCANOUT_DDR_SIZE) {
			fprintf(stderr, "blitscrt: %ux%u at %u bpp needs %zu bytes, "
					"reserved window is %u\n",
				w, h, bpp, need, BLITSCRT_SCANOUT_DDR_SIZE);
			return -1;
		}
		if (map_scanout_window(f) < 0)
			return -1;

		blitscrt_fabric_write(f, BLITSCRT_REG_SCANOUT_BASE, f->sc_phys);
	}

	blitscrt_fabric_write(f, BLITSCRT_REG_SCANOUT_GEOM,
			      ((uint32_t)h << 16) | (w & 0xffffu));
	blitscrt_fabric_write(f, BLITSCRT_REG_SCANOUT_STRIDE, f->sc_stride);
	blitscrt_fabric_write(f, BLITSCRT_REG_SCANOUT_FORMAT, format);
	blitscrt_fabric_write(f, BLITSCRT_REG_APPLY, 1);

	/* Read it back. Writing a register and reporting success from the value
	 * that was written proves nothing -- a dropped write, a stale bitstream
	 * or a read-only register all look identical from the writing side. */
	{
		uint32_t g = blitscrt_fabric_read(f, BLITSCRT_REG_SCANOUT_GEOM);
		if ((g & 0xffffu) != w || ((g >> 16) & 0xffffu) != h) {
			fprintf(stderr, "blitscrt: geometry did not take -- asked for "
					"%ux%u, reads back %ux%u\n",
				w, h, g & 0xffffu, (g >> 16) & 0xffffu);
			return -1;
		}
	}
	return 0;
}

int blitscrt_fabric_live(struct blitscrt_fabric *f, struct blitscrt_live *o)
{
	uint32_t h1, h2, v1, v2, mi;

	if (!f || !o) return -1;
	h1 = blitscrt_fabric_read(f, BLITSCRT_REG_LIVE_H1);
	h2 = blitscrt_fabric_read(f, BLITSCRT_REG_LIVE_H2);
	v1 = blitscrt_fabric_read(f, BLITSCRT_REG_LIVE_V1);
	v2 = blitscrt_fabric_read(f, BLITSCRT_REG_LIVE_V2);
	mi = blitscrt_fabric_read(f, BLITSCRT_REG_LIVE_MISC);

	o->h_sy = h1 & 0xffffu;  o->h_bp = h1 >> 16;
	o->h_act = h2 & 0xffffu; o->h_fp = h2 >> 16;
	o->v_sy = v1 & 0xffffu;  o->v_bp = v1 >> 16;
	o->v_act = v2 & 0xffffu; o->v_fp = v2 >> 16;
	o->h_total = o->h_sy + o->h_bp + o->h_act + o->h_fp;
	o->v_total = o->v_sy + o->v_bp + o->v_act + o->v_fp;
	o->interlace  = (mi & BLITSCRT_LIVE_INTERLACE)  ? 1 : 0;
	o->hps_timing = (mi & BLITSCRT_LIVE_HPS_TIMING) ? 1 : 0;
	o->clk_sel = BLITSCRT_LIVE_CLKSEL(mi);

	/* Slots 0 and 1 are the 50 MHz reference pin, not a PLL output. Reading
	 * one of those back means the raster is not on a pixel clock at all. */
	o->pclk_hz = (o->clk_sel < 2) ? 50.0e6 :
		     (double)blitscrt_fabric_read(f, BLITSCRT_REG_PCLK_KHZ) * 1000.0;
	o->line_hz  = o->h_total ? o->pclk_hz / o->h_total : 0.0;
	o->field_hz = o->v_total ? o->line_hz / o->v_total : 0.0;
	return 0;
}

int blitscrt_scanout_geom(struct blitscrt_fabric *f, unsigned *w, unsigned *h)
{
	if (!f || !f->sc_w || !f->sc_h)
		return -1;
	if (w) *w = f->sc_w;
	if (h) *h = f->sc_h;
	return 0;
}

void blitscrt_scanout_seek(struct blitscrt_fabric *f, uint32_t index)
{
	if (!f) return;
	blitscrt_fabric_write(f, BLITSCRT_REG_SCANOUT_WADDR, index);
}

/*
 * A damage rectangle. Runs of consecutive pixels is all one is, so each row is
 * a seek followed by the run -- no address traffic between pixels, which is
 * what the auto-incrementing pointer is for.
 *
 * src is packed w pixels per row, which is how GUD delivers a rect. Returns the
 * number of pixels written, after clipping to the memory that is actually
 * fitted; a rect entirely outside it writes nothing rather than wrapping.
 */
long blitscrt_scanout_blit(struct blitscrt_fabric *f,
			   unsigned x, unsigned y, unsigned w, unsigned h,
			   const uint16_t *src)
{
	unsigned row, col;
	uint32_t w_src;                  /* rect width as sent, before clipping */
	long n = 0;

	if (!f || !src) return -1;
	if (!f->sc_w || !f->sc_h) {
		fprintf(stderr, "blitscrt: fabric reports no scanout geometry\n");
		return -1;
	}
	if (x >= f->sc_w || y >= f->sc_h) return 0;

	/*
	 * Clipping the width must not change how far the source advances.
	 *
	 * src holds w_src pixels per row, whatever the scanout is. Clipping w
	 * and then striding the source by the clipped value reads row 0's left
	 * half, then row 0's right half as though it were row 1 -- a 640-wide
	 * image squeezed into a 320-wide raster and doubled vertically, rather
	 * than the left half cropped.
	 *
	 * That happens whenever the host's framebuffer is larger than the mode,
	 * which an X screen that has not followed a mode change does routinely.
	 */
	w_src = w;
	if (w > f->sc_w - x) w = f->sc_w - x;
	if (h > f->sc_h - y) h = f->sc_h - y;

	/* DDR3: a rect is h row-copies into the window. Row-granular memcpy costs
	 * nothing against one large copy -- measured 111 MB/s in 1280-byte rows
	 * against 110 for 8 MB in one go -- so a narrow rect is not penalised. */
	if (f->caps & BLITSCRT_CAP_SCANOUT_DDR3) {
		if (!f->sc_win && map_scanout_window(f) < 0) return -1;
		for (row = 0; row < h; row++)
			memcpy((void *)(f->sc_win + (size_t)(y + row) * f->sc_stride
					+ (size_t)x * f->sc_bpp),
			       (const uint8_t *)src + (size_t)row * w_src * f->sc_bpp,
			       (size_t)w * f->sc_bpp);
		return (long)w * h;
	}

	for (row = 0; row < h; row++) {
		blitscrt_scanout_seek(f, (uint32_t)((y + row) * f->sc_w + x));
		for (col = 0; col < w; col++, n++)
			blitscrt_fabric_write16(f, BLITSCRT_REG_SCANOUT_WDATA,
						src[row * w_src + col]);
	}
	return n;
}

long blitscrt_scanout_fill(struct blitscrt_fabric *f,
			   unsigned x, unsigned y, unsigned w, unsigned h,
			   uint16_t colour)
{
	unsigned row, col;
	long n = 0;

	if (!f) return -1;
	if (!f->sc_w || !f->sc_h) {
		fprintf(stderr, "blitscrt: fabric reports no scanout geometry\n");
		return -1;
	}
	if (x >= f->sc_w || y >= f->sc_h) return 0;
	if (w > f->sc_w - x) w = f->sc_w - x;
	if (h > f->sc_h - y) h = f->sc_h - y;

	if (f->caps & BLITSCRT_CAP_SCANOUT_DDR3) {
		/* Build one row, then copy it down. memset only works when both
		 * bytes of the pixel match, and a per-pixel store loop gives up
		 * a third of the bandwidth on an uncached mapping. */
		uint16_t *rowbuf;
		if (!f->sc_win && map_scanout_window(f) < 0) return -1;
		rowbuf = malloc((size_t)w * f->sc_bpp);
		if (!rowbuf) return -1;
		for (col = 0; col < w; col++) rowbuf[col] = colour;
		for (row = 0; row < h; row++)
			memcpy((void *)(f->sc_win + (size_t)(y + row) * f->sc_stride
					+ (size_t)x * f->sc_bpp),
			       rowbuf, (size_t)w * f->sc_bpp);
		free(rowbuf);
		return (long)w * h;
	}

	for (row = 0; row < h; row++) {
		blitscrt_scanout_seek(f, (uint32_t)((y + row) * f->sc_w + x));
		for (col = 0; col < w; col++, n++)
			blitscrt_fabric_write16(f, BLITSCRT_REG_SCANOUT_WDATA,
						colour);
	}
	return n;
}

void blitscrt_fabric_set_tick(struct blitscrt_fabric *f,
			      void (*fn)(void *), void *arg)
{
	if (!f) return;
	f->tick_fn  = fn;
	f->tick_arg = arg;
}

static void fabric_tick(struct blitscrt_fabric *f)
{
	if (f && f->tick_fn) f->tick_fn(f->tick_arg);
}

int blitscrt_fabric_pll_reconfig(struct blitscrt_fabric *f,
				 const struct pll_config *p)
{
	struct pll_reconfig_seq q;
	unsigned int i;

	if (!f || !p)
		return -1;
	if (pll_reconfig_build(p, 0, &q) < 0)
		return -1;

	/* Log exactly what goes out. blitscrt-peek -R sends what should be the
	 * identical sequence and succeeds where this fails, so the bytes are
	 * worth comparing rather than assumed equal. */
	if (getenv("BLITSCRT_PLL_TRACE"))
		for (i = 0; i < q.count; i++)
			fprintf(stderr, "  pll write [0x%04x] word %u = 0x%08x\n",
				(unsigned)(BLITSCRT_PLLRECFG_OFFSET +
					   q.w[i].addr * 4),
				q.w[i].addr, q.w[i].data);

	for (i = 0; i < q.count; i++)
		blitscrt_fabric_write(f, BLITSCRT_PLLRECFG_OFFSET +
					 (q.w[i].addr * 4), q.w[i].data);

	/* Busy clears when the counters are shifted in, lock returns some
	 * microseconds later. The pixel clock is unusable in between, which is
	 * why the caller holds the video pipeline in reset. */
	{
		/*
		 * Poll STATUS. It is safe to, and the old comment here was
		 * wrong.
		 *
		 * This used to back off -- 5, 10, 20 ... 640 ms between single
		 * reads -- on the theory that reading STATUS while the core
		 * waits for lock stops it ever reaching LOCKED. It does not.
		 * Two separate causes were mistaken for that:
		 *
		 *   1. MODE. `status` is literally (current_state == LOCKED),
		 *      and in waitrequest mode the machine returns from
		 *      WAIT_ON_LOCK straight to IDLE and never enters LOCKED.
		 *      MODE=0 plus polling can therefore never succeed, at any
		 *      interval. pll_reconfig_build() writes PLL_MODE_POLL.
		 *   2. The mgmt read FSM. Holding mgmt_read re-ran the slave's
		 *      read FSM, whose readdata alternates between the value
		 *      and zero while it cycles -- the garbage that prompted
		 *      the delay in the first place. Fixed in regs 3.8, and
		 *      this daemon warns below that version.
		 *
		 * sim/tb_pll_reconfig.v polls STATUS 200 times with no gap at
		 * all, real IP through the real bridge, and reaches ready.
		 *
		 * The floor below is not superstition: lock does not drop the
		 * instant the counters shift in, so an immediate read can see
		 * the PREVIOUS mode still LOCKED and return before the new
		 * clock is up. That race is the only reason to wait at all.
		 */
		enum { PLL_FLOOR_US = 200, PLL_GAP_US = 50,
		       PLL_DEADLINE_US = 20000 };
		uint32_t st = 0;
		unsigned total = 0;
		struct timespec t0, now;

		usleep(PLL_FLOOR_US);
		clock_gettime(CLOCK_MONOTONIC, &t0);
		for (;;) {
			st = blitscrt_fabric_read(f, BLITSCRT_PLLRECFG_OFFSET +
						      (PLL_RECONFIG_STATUS * 4));
			if (st & PLL_STATUS_READY) {
				if (total > 2000)
					fprintf(stderr, "blitscrt: PLL ready "
						"after %u us\n",
						total + PLL_FLOOR_US);
				return 0;
			}
			clock_gettime(CLOCK_MONOTONIC, &now);
			total = (unsigned)((now.tv_sec - t0.tv_sec) * 1000000
				 + (now.tv_nsec - t0.tv_nsec) / 1000);
			if (total > PLL_DEADLINE_US)
				break;
			usleep(PLL_GAP_US);
		}
		/* Well inside the ~1.5 s watchdog now, so no tick slicing. */
		fabric_tick(f);
		total = (total + PLL_FLOOR_US) / 1000;
		fprintf(stderr,
			"blitscrt: PLL reconfig did not complete after %u ms\n"
			"  STATUS  (0x%04x) = 0x%08x  ready=%d\n"
			"  MODE    (0x%04x) = 0x%08x\n"
			"  STATUS is (state == LOCKED). MODE must read 1: in\n"
			"  waitrequest mode the core never enters LOCKED, so\n"
			"  STATUS can never read ready however long this waits.\n"
			"  BUS_DIAG = 0x%08x -- starts/counter-writes/accepts\n"
			"  reaching the reconfig slave, and bit 3 is PLL lock.\n"
			"  All zero there means the sequence never arrived,\n"
			"  which is a transport fault, not a PLL one.\n",
			total,
			BLITSCRT_PLLRECFG_OFFSET + PLL_RECONFIG_STATUS * 4, st,
			(st & PLL_STATUS_READY) ? 1 : 0,
			BLITSCRT_PLLRECFG_OFFSET + PLL_RECONFIG_MODE * 4,
			blitscrt_fabric_read(f, BLITSCRT_PLLRECFG_OFFSET +
						PLL_RECONFIG_MODE * 4),
			blitscrt_fabric_read(f, BLITSCRT_REG_BUS_DIAG));
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

	/*
	 * The active area is part of the mode, so geometry moves with it. Leaving
	 * it behind gives a raster of one height reading a picture of another:
	 * applying 576i while scanout still believed 480 lines put the bottom
	 * 96 lines outside the bounds clamp.
	 *
	 * Height is the FRAME height. scanout reads a progressive surface and
	 * interleaves on the way out, so an interlaced mode needs both fields'
	 * worth of lines in memory -- t->v_act is per field.
	 */
	{
		unsigned fh = t->v_act *
			      ((t->mode_flags & BLITSCRT_MODE_INTERLACE) ? 2u : 1u);
		if (blitscrt_scanout_configure(f, t->h_act, fh, fmt) < 0)
			return -1;
	}

	/*
	 * The whole modeline, once per modeset.
	 *
	 * The per-second fps line carries the resolution and nothing else, which
	 * is enough to see *that* a mode is running and useless for asking
	 * whether it is running at the right rate. A picture that is subtly wrong
	 * -- a monitor not quite locking, pixels leaning -- is a question about
	 * porches and the achieved pixel clock, and neither was ever printed.
	 *
	 * ppm is the honest number: the PLL solves M/N/C over integers, so the
	 * clock it reaches is rarely the one asked for. 0 ppm is exact; a few
	 * hundred is a frame slipping every half minute or so.
	 */
	{
		int il = (t->mode_flags & BLITSCRT_MODE_INTERLACE) ? 1 : 0;
		char frac[40];

		/* k is the 32-bit numerator on M, zero on an integer solve. Say
		 * so, because which solver ran is the first thing to check if a
		 * mode judders or shows patterned noise. */
		if (t->pll.k)
			snprintf(frac, sizeof frac, "+%u/2^32 (fractional)",
				 t->pll.k);
		else
			frac[0] = '\0';

		/* line_hz and field_hz come from mode_check, computed against
		 * the clock actually solved rather than the one requested. */
		fprintf(stderr,
			"blitscrt: mode %ux%u%s applied\n"
			"  H   %u %u %u %u   total %u\n"
			"  V   %u %u %u %u   total %u%s\n"
			"  clk %.6f MHz asked, %.6f MHz solved (%+lld ppm)\n"
			"  PLL M=%u%s N=%u C=%u\n"
			"  ->  %.3f kHz line, %.2f Hz %s, %u lines a frame\n"
			"  host renders at %.2f Hz%s%s\n",
			t->h_act, t->v_act, il ? "i" : "p",
			t->h_sy, t->h_bp, t->h_act, t->h_fp, t->h_total,
			t->v_sy, t->v_bp, t->v_act, t->v_fp,
			t->v_total_field, il ? " per field" : "",
			t->pll.target_hz / 1e6,
			t->pll.actual_hz / 1e6,
			t->pll.error_ppm,
			t->pll.m, frac, t->pll.n, t->pll.c,
			t->line_hz / 1000.0,
			il ? t->field_hz : t->frame_hz,
			il ? "field" : "frame",
			t->frame_lines,
			/*
			 * What the host is drawing at, which is not always what
			 * reaches the screen.
			 *
			 * DRM derives a mode's refresh as clock/(htotal*vtotal)
			 * and doubles it for an interlaced mode, because the
			 * framebuffer holds whole frames and the hardware picks
			 * alternate lines. So an interlaced mode wants the FRAME
			 * vtotal advertised, not the per-field one: 525 for
			 * 480i, giving 30 doubled to 60.
			 *
			 * Send 262 instead and DRM reads 60 and doubles to 120;
			 * send a frame count where a field count belongs and it
			 * halves. Either way the host renders at the wrong rate
			 * and nothing else complains, so it is printed here
			 * beside the rate the CRT actually gets.
			 */
			(t->h_total && t->frame_lines)
			  ? (double)t->pll.actual_hz /
			    ((double)t->h_total * t->frame_lines) * (il ? 2 : 1)
			  : 0.0,
			il ? " (interlaced: DRM doubles the frame rate)" : "",
			t->from_progressive
			  ? "\n  rewritten from a 31 kHz progressive mode: the host"
			    " renders whole\n  frames at the field rate, so each"
			    " field is a different render"
			  : "");
		fflush(stderr);
	}

	/* Claim the raster, then check what it is actually running.
	 *
	 * This began as a workaround. The APPLYING bit was not trustworthy across
	 * a reconfiguration: the video-side apply_ack was reset by something a
	 * clock change disturbs while apply_req kept its value in the bus domain,
	 * so the toggle handshake could come back disagreeing and a mode that
	 * visibly applied was reported as a failure. That is fixed -- the latch
	 * resets on vid_cfg_rst_n, power-on and the reset button, rather than on
	 * vid_rst_n, and tb_regs.v asserts it survives a clock change.
	 *
	 * The read-back stays anyway. Confirming against the raster is worth more
	 * than confirming against a status bit even when the bit is right, and it
	 * is the same rule as configure(): read back what happened rather than
	 * trusting that a write meant what it said.
	 */
	{
		uint32_t c = blitscrt_fabric_read(f, BLITSCRT_REG_CTRL);
		blitscrt_fabric_write(f, BLITSCRT_REG_CTRL,
				      c | BLITSCRT_CTRL_HPS_TIMING);
	}

	/*
	 * Wait on a clock, not on a loop count.
	 *
	 * The staged timing latches at a vblank -- that is the whole point of
	 * the handshake, so a mode never changes mid-frame. At 60 Hz the next
	 * one is up to 16.7 ms away, and slower at 50 Hz or on a long-vtotal
	 * mode.
	 *
	 * This used to spin 200 times with no delay between reads. Two hundred
	 * register reads over the gp bridge take well under a millisecond, so
	 * the loop could expire before the vblank ever arrived and report a
	 * modeset as failed while it was about to succeed. Intermittent by
	 * nature: whether it caught the vblank depended on where in the frame
	 * the request landed.
	 *
	 * 100 ms covers several frames at any rate this project supports, and
	 * a modeset is rare enough that waiting is free.
	 */
	{
		enum { CONFIRM_DEADLINE_US = 100000, CONFIRM_GAP_US = 200 };
		struct timespec c0, cnow;
		unsigned waited = 0;

		clock_gettime(CLOCK_MONOTONIC, &c0);
		for (spin = 0; ; spin++) {
			struct blitscrt_live lv;
			if (blitscrt_fabric_live(f, &lv) < 0)
				return -1;
			if (lv.hps_timing && lv.h_act == t->h_act &&
			    lv.h_total == t->h_total &&
			    lv.v_total == t->v_total_field &&
			    lv.interlace ==
			      ((t->mode_flags & BLITSCRT_MODE_INTERLACE) ? 1 : 0)) {
				if (waited > 20000)
					fprintf(stderr, "blitscrt: mode latched "
							"after %u ms\n",
						waited / 1000);
				return 0;
			}
			clock_gettime(CLOCK_MONOTONIC, &cnow);
			waited = (unsigned)((cnow.tv_sec - c0.tv_sec) * 1000000
				 + (cnow.tv_nsec - c0.tv_nsec) / 1000);
			if (waited > CONFIRM_DEADLINE_US)
				break;
			usleep(CONFIRM_GAP_US);
		}
	}
	{
		struct blitscrt_live lv;
		if (blitscrt_fabric_live(f, &lv) == 0)
			fprintf(stderr, "blitscrt: mode did not take -- asked H %u "
					"total %u, V total %u%s; raster reports H "
					"%u total %u, V total %u%s, clk_sel %u\n",
				t->h_act, t->h_total, t->v_total_field,
				(t->mode_flags & BLITSCRT_MODE_INTERLACE) ? " i" : "",
				lv.h_act, lv.h_total, lv.v_total,
				lv.interlace ? " i" : "", lv.clk_sel);
	}
	return -1;
}

int blitscrt_fabric_take_user_press(struct blitscrt_fabric *f)
{
	uint32_t v;

	if (!f) return 0;
	if (blitscrt_fabric_read(f, BLITSCRT_REG_VERSION) < 0x00030014u)
		return 0;                       /* register did not exist */

	v = blitscrt_fabric_read(f, BLITSCRT_REG_BTN_EVENT);
	if (!(v & BLITSCRT_BTN_EVENT_USER))
		return 0;

	/* Write-one-to-clear, so the press is consumed exactly once even if
	 * something else is reading the register at the same time. */
	blitscrt_fabric_write(f, BLITSCRT_REG_BTN_EVENT,
			      BLITSCRT_BTN_EVENT_USER);
	return 1;
}

unsigned blitscrt_fabric_max_width(struct blitscrt_fabric *f)
{
	if (!f) return 0;
	if (blitscrt_fabric_read(f, BLITSCRT_REG_VERSION) < 0x0003000Bu)
		return 0;                           /* register did not exist */
	return blitscrt_fabric_read(f, BLITSCRT_REG_SCANOUT_MAXW) & 0xfffu;
}

void blitscrt_fabric_overlay_show(struct blitscrt_fabric *f, int on)
{
	uint32_t c;
	if (!f) return;
	c = blitscrt_fabric_read(f, BLITSCRT_REG_CTRL);
	if (on) c |=  BLITSCRT_CTRL_OVERLAY;
	else    c &= ~BLITSCRT_CTRL_OVERLAY;
	blitscrt_fabric_write(f, BLITSCRT_REG_CTRL, c);
}

void blitscrt_fabric_enable(struct blitscrt_fabric *f, int on)
{
	uint32_t c;
	if (!f) return;
	c = blitscrt_fabric_read(f, BLITSCRT_REG_CTRL);
	/* Hand the raster back to the front-panel mode table when the host goes.
	 * A mode the host asked for is only meaningful while it is there, and the
	 * table is a known-good mode that needs no software. */
	if (!on) c &= ~BLITSCRT_CTRL_HPS_TIMING;
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
