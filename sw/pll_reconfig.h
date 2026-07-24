/* SPDX-License-Identifier: MIT */
#ifndef BLITSCRT_PLL_RECONFIG_H
#define BLITSCRT_PLL_RECONFIG_H

#include <stdint.h>
#include "pll.h"

/*
 * altera_pll_reconfig Avalon-MM register map, word addressed.
 *
 * VERIFY against the Cyclone V "Reconfiguring PLLs" guide for the IP version
 * actually generated. The addresses below are the standard map, but the IP has
 * options that move things, and a wrong write here mis-clocks the video rather
 * than failing loudly.
 */
#define PLL_RECONFIG_MODE       0x0     /* 0 = poll busy, 1 = interrupt        */
#define PLL_RECONFIG_STATUS     0x1     /* bit0 busy, bit1 locked              */
#define PLL_RECONFIG_START      0x2     /* any write latches the counter set   */
#define PLL_RECONFIG_N          0x3
#define PLL_RECONFIG_M          0x4
#define PLL_RECONFIG_C          0x5     /* counter select in the upper bits    */
#define PLL_RECONFIG_PHASE      0x6
#define PLL_RECONFIG_K          0x7     /* fractional M, unused here           */

#define PLL_STATUS_BUSY         (1u << 0)
#define PLL_STATUS_LOCKED       (1u << 1)

/*
 * Counter word layout. The high and low half-periods are eight bits each, so
 * the largest divide that can be encoded is 255 + 255 = 510, not the 512 the
 * device datasheet quotes for the counters themselves. Programming 511 or 512
 * would wrap the high field and silently mis-clock the video.
 *
 * VERIFY the field width against the guide for the generated IP. Some variants
 * carry nine-bit halves, which would lift the ceiling to 1022.
 */
#define PLL_CNT_FIELD_BITS      8
#define PLL_CNT_MAX             ((1u << PLL_CNT_FIELD_BITS) - 1u)
#define PLL_DIVIDE_MAX          (PLL_CNT_MAX * 2u)

#define PLL_CNT_LOW_SHIFT       0
#define PLL_CNT_HIGH_SHIFT      8
#define PLL_CNT_BYPASS_SHIFT    16
#define PLL_CNT_ODD_SHIFT       17
#define PLL_C_SELECT_SHIFT      18

struct pll_counter {
	unsigned int divide;
	unsigned int high, low;
	unsigned int bypass, odd_duty;
	uint32_t     raw;
};

struct pll_reconfig_write {
	uint32_t addr;
	uint32_t data;
};

struct pll_reconfig_seq {
	struct pll_counter n, m, c;
	unsigned int c_index;
	struct pll_reconfig_write w[8];
	unsigned int count;
};

/* Returns a counter with .divide == 0 if the value cannot be encoded. */
struct pll_counter pll_encode_counter(unsigned int divide);
unsigned int       pll_decode_counter(uint32_t raw);

/* Turn a solved pll_config into the write sequence. 0 on success. */
int pll_reconfig_build(const struct pll_config *p,
		       unsigned int c_index,
		       struct pll_reconfig_seq *out);

#endif
