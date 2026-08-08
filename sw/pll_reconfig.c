/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * pll_reconfig.c -- drive altera_pll_reconfig on Cyclone V.
 *
 * `sw/pll.c` solves M, N and C for any pixel clock a host asks for. This is
 * what gets those numbers into the PLL at runtime, which is the difference
 * between validating an arbitrary Switchres modeline and actually producing it.
 *
 * The counters are not written as plain divide values. Each one is split into a
 * high and a low half-period so the hardware can make an odd divide by holding
 * one phase a cycle longer:
 *
 *   divide 1     bypass the counter entirely
 *   divide even  high = low = D/2,          odd_duty = 0
 *   divide odd   high = (D+1)/2, low = D/2, odd_duty = 1
 *
 * A reconfiguration is: write every counter, write the start register, wait for
 * busy to clear, then wait for the PLL to relock. The output is unusable while
 * that happens, so the video pipeline is held in reset across it in the same way
 * a clock mux switch is.
 */

#include "pll_reconfig.h"

#include <stddef.h>

struct pll_counter pll_encode_counter(unsigned int divide)
{
	struct pll_counter c;

	c.raw = 0;
	c.divide = divide;

	if (divide > PLL_DIVIDE_MAX) {
		/* Would wrap the high field and mis-clock the video with no
		 * error anywhere. Refuse instead. */
		c.divide = 0;
		c.high = c.low = c.bypass = c.odd_duty = 0;
		return c;
	}

	if (divide <= 1) {
		/* A counter set to 1 is bypassed rather than programmed. */
		c.bypass = 1;
		c.odd_duty = 0;
		c.high = 1;
		c.low = 1;
	} else {
		c.bypass = 0;
		c.odd_duty = divide & 1u;
		c.high = (divide + 1u) / 2u;    /* the longer half when odd */
		c.low  = divide / 2u;
	}

	c.raw = ((uint32_t)(c.odd_duty & 1u) << PLL_CNT_ODD_SHIFT) |
		((uint32_t)(c.bypass   & 1u) << PLL_CNT_BYPASS_SHIFT) |
		((uint32_t)(c.high  & 0xffu) << PLL_CNT_HIGH_SHIFT) |
		((uint32_t)(c.low   & 0xffu) << PLL_CNT_LOW_SHIFT);

	return c;
}

unsigned int pll_decode_counter(uint32_t raw)
{
	if (raw & (1u << PLL_CNT_BYPASS_SHIFT))
		return 1;
	return ((raw >> PLL_CNT_HIGH_SHIFT) & 0xffu) +
	       ((raw >> PLL_CNT_LOW_SHIFT)  & 0xffu);
}

int pll_reconfig_build(const struct pll_config *p,
		       unsigned int c_index,
		       struct pll_reconfig_seq *out)
{
	struct pll_counter n, m, c;

	if (!p || !out || c_index > 17)
		return -1;
	if (!p->m || !p->n || !p->c)
		return -1;
	if (p->m > PLL_DIVIDE_MAX || p->n > PLL_DIVIDE_MAX ||
	    p->c > PLL_DIVIDE_MAX)
		return -1;

	n = pll_encode_counter(p->n);
	m = pll_encode_counter(p->m);
	c = pll_encode_counter(p->c);
	if (!n.divide || !m.divide || !c.divide)
		return -1;

	out->n = n;
	out->m = m;
	out->c = c;
	out->c_index = c_index;

	out->count = 0;

	/* Polling mode -- 1, not 0. See PLL_RECONFIG_MODE in the header: 0 is
	 * waitrequest mode, where the slave stalls on START and never enters the
	 * LOCKED state that `status` reports. We poll STATUS, so we need 1. */
	out->w[out->count].addr = PLL_RECONFIG_MODE;
	out->w[out->count].data = PLL_MODE_POLL;
	out->count++;

	out->w[out->count].addr = PLL_RECONFIG_N;
	out->w[out->count].data = n.raw;
	out->count++;

	out->w[out->count].addr = PLL_RECONFIG_M;
	out->w[out->count].data = m.raw;
	out->count++;

	/*
	 * The fractional numerator on M, when there is one.
	 *
	 * Written unconditionally: k is zero for an integer solution, and zero
	 * is what an integer PLL wants there anyway, so the same write sequence
	 * suits both cores. That is what lets the fractional IP be swapped in
	 * by changing two QIP_FILE lines and nothing else.
	 *
	 * On a PLL generated without fractional support the register is simply
	 * not implemented and the write is discarded -- so this is safe against
	 * the integer core rather than merely harmless.
	 */
	out->w[out->count].addr = PLL_RECONFIG_K;
	out->w[out->count].data = p->k;
	out->count++;

	/* The C write carries which of the eighteen output counters it means. */
	out->w[out->count].addr = PLL_RECONFIG_C;
	out->w[out->count].data = c.raw |
		((uint32_t)(c_index & 0x1fu) << PLL_C_SELECT_SHIFT);
	out->count++;

	/* Any write to START latches the whole set. */
	out->w[out->count].addr = PLL_RECONFIG_START;
	out->w[out->count].data = 1;
	out->count++;

	return 0;
}
