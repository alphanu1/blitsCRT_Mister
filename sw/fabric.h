/* SPDX-License-Identifier: MIT */
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

/* Reprogram the pixel clock. Returns 0 once the PLL reports lock again. */
int blitscrt_fabric_pll_reconfig(struct blitscrt_fabric *f,
				 const struct pll_config *p);

/* Push timing and PLL counters, then latch on the next vblank. */
int  blitscrt_fabric_set_mode(struct blitscrt_fabric *f,
			      const struct blitscrt_timing *t, uint8_t format);
void blitscrt_fabric_enable(struct blitscrt_fabric *f, int on);

/* Write a line of text into the overlay character buffer. */
void blitscrt_fabric_overlay_line(struct blitscrt_fabric *f,
				  unsigned row, unsigned col, const char *s);
void blitscrt_fabric_overlay_clear(struct blitscrt_fabric *f);

#endif
