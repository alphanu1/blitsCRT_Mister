/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef BLITSCRT_FABRIC_H
#define BLITSCRT_FABRIC_H

#include <stdint.h>
#include "modes.h"
#include "pll_reconfig.h"

struct blitscrt_fabric;

/* NULL if /dev/mem is unavailable or the ID register does not answer */
struct blitscrt_fabric *blitscrt_fabric_open(void);
void blitscrt_fabric_close(struct blitscrt_fabric *f);

uint32_t blitscrt_fabric_read(struct blitscrt_fabric *f, uint32_t off);
void     blitscrt_fabric_write(struct blitscrt_fabric *f, uint32_t off, uint32_t v);

/* One transport command, for registers that are 16 bits wide. Halves the cost
 * of the rect path against the 32-bit call. */
void     blitscrt_fabric_write16(struct blitscrt_fabric *f, uint32_t off, uint16_t v);

/*
 * Scanout memory. Damage rectangles go straight in; nothing is presented and
 * nothing is flipped. Geometry is read off the fabric at open, so a caller never
 * has to know what memory is fitted.
 *
 * blit and fill return the pixel count actually written after clipping, or -1 if
 * the fabric reported no geometry.
 */
/* BLITSCRT_CAP_*, read from the fabric at open. Zero means an older bitstream
 * that does not report; treat capabilities as unknown rather than absent. */
uint32_t blitscrt_fabric_caps(struct blitscrt_fabric *f);

/* Set geometry, stride, base and format together, and on a DDR3 build map the
 * reserved window. Everything latches on the next vblank. */
int  blitscrt_scanout_configure(struct blitscrt_fabric *f,
				unsigned w, unsigned h, uint32_t format);

/* The timing video_timing is actually being fed, after the ownership mux. Not
 * what was staged: those can differ, and only this says which is on screen. */
struct blitscrt_live {
	unsigned h_sy, h_bp, h_act, h_fp, h_total;
	unsigned v_sy, v_bp, v_act, v_fp, v_total;
	int      interlace, hps_timing;
	unsigned clk_sel;
	double   pclk_hz, line_hz, field_hz;
};
int  blitscrt_fabric_live(struct blitscrt_fabric *f, struct blitscrt_live *o);

int  blitscrt_scanout_geom(struct blitscrt_fabric *f, unsigned *w, unsigned *h);
void blitscrt_scanout_seek(struct blitscrt_fabric *f, uint32_t index);
long blitscrt_scanout_blit(struct blitscrt_fabric *f,
			   unsigned x, unsigned y, unsigned w, unsigned h,
			   const uint16_t *src);
long blitscrt_scanout_fill(struct blitscrt_fabric *f,
			   unsigned x, unsigned y, unsigned w, unsigned h,
			   uint16_t colour);

/* Reprogram the pixel clock. Returns 0 once the PLL reports lock again. */
/*
 * Called during waits long enough to starve the fabric watchdog -- the PLL
 * reconfiguration backoff runs to about 1.3 s. Without it the raster reverts to
 * the front-panel test card mid-modeset, which looks like the daemon having died
 * when it is only waiting for a PLL to relock.
 *
 * A callback, so fabric.c need not know about the device layer.
 */
void blitscrt_fabric_set_tick(struct blitscrt_fabric *f,
			      void (*fn)(void *), void *arg);

int blitscrt_fabric_pll_reconfig(struct blitscrt_fabric *f,
				 const struct pll_config *p);

/* Push timing and PLL counters, then latch on the next vblank. */
int  blitscrt_fabric_set_mode(struct blitscrt_fabric *f,
			      const struct blitscrt_timing *t, uint8_t format);
void blitscrt_fabric_enable(struct blitscrt_fabric *f, int on);

/* Show or hide the text overlay (CTRL bit 2). The front-panel button is ANDed
 * with this in the fabric and stays authoritative, so a button press still hides
 * the text whatever software wants. */
void blitscrt_fabric_overlay_show(struct blitscrt_fabric *f, int on);

/* Write a line of text into the overlay character buffer. */
void blitscrt_fabric_overlay_line(struct blitscrt_fabric *f,
				  unsigned row, unsigned col, const char *s);
void blitscrt_fabric_overlay_clear(struct blitscrt_fabric *f);

#endif
