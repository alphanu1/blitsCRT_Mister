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
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

struct blitscrt_fabric {
	int      fd;
	volatile uint8_t *base;
	size_t   span;
};

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

	aligned = BLITSCRT_LWBRIDGE_BASE & ~(off_t)(page - 1);
	f->span = BLITSCRT_REG_SPAN + (BLITSCRT_LWBRIDGE_BASE - aligned);
	f->base = mmap(NULL, f->span, PROT_READ | PROT_WRITE, MAP_SHARED,
		       f->fd, aligned);
	if (f->base == MAP_FAILED) {
		close(f->fd);
		free(f);
		return NULL;
	}
	f->base += (BLITSCRT_LWBRIDGE_BASE - aligned);

	if (blitscrt_fabric_read(f, BLITSCRT_REG_ID) != BLITSCRT_ID_MAGIC) {
		fprintf(stderr, "blitscrt: no ID magic at 0x%08X, wrong bitstream?\n",
			BLITSCRT_LWBRIDGE_BASE);
		blitscrt_fabric_close(f);
		return NULL;
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

uint32_t blitscrt_fabric_read(struct blitscrt_fabric *f, uint32_t off)
{
	return *(volatile uint32_t *)(f->base + off);
}

void blitscrt_fabric_write(struct blitscrt_fabric *f, uint32_t off, uint32_t v)
{
	*(volatile uint32_t *)(f->base + off) = v;
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
	for (r = 0; r < BLITSCRT_CHARRAM_ROWS; r++)
		for (c = 0; c < BLITSCRT_CHARRAM_COLS; c++)
			blitscrt_fabric_write(f,
				BLITSCRT_CHARRAM_OFFSET +
				((r * BLITSCRT_CHARRAM_COLS + c) * 4),
				BLITSCRT_CHAR_BLANK);
}

void blitscrt_fabric_overlay_line(struct blitscrt_fabric *f,
				  unsigned row, unsigned col, const char *s)
{
	unsigned i;
	if (!f || row >= BLITSCRT_CHARRAM_ROWS) return;
	for (i = 0; s[i] && col + i < BLITSCRT_CHARRAM_COLS; i++) {
		uint8_t ch = (uint8_t)s[i];
		if (ch == ' ') ch = BLITSCRT_CHAR_BACKED;
		blitscrt_fabric_write(f,
			BLITSCRT_CHARRAM_OFFSET +
			(((row * BLITSCRT_CHARRAM_COLS) + col + i) * 4),
			ch & 0x7F);
	}
}
