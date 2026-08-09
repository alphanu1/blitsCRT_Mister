/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef BLITSCRT_PLL_H
#define BLITSCRT_PLL_H

struct pll_limits {
	unsigned long long fin_hz;
	unsigned long long vco_min_hz, vco_max_hz;
	unsigned long long pfd_min_hz, pfd_max_hz;
	unsigned int m_min, m_max;
	unsigned int n_min, n_max;
	unsigned int c_min, c_max;
};

struct pll_config {
	unsigned int m, n, c;
	/*
	 * Fractional numerator on the M counter, 32 bits, so the effective
	 * multiplier is m + k/2^32. Zero on an integer solution, and zero is
	 * also what an integer PLL wants written -- so a config solved either
	 * way can be applied to either PLL without the caller caring.
	 *
	 * The generated fractional IP reports the same arrangement:
	 *   fractional_cout(32)  fractional_division("274877907")
	 * where 274877907/2^32 is 0.064, giving M = 8.064 for 12.600 MHz.
	 */
	unsigned int k;
	unsigned long long vco_hz;
	unsigned long long target_hz;
	unsigned long long actual_hz;
	long long error_hz;
	long long error_ppm;
	unsigned long ops;          /* search cost, for sanity checking */
};

extern const struct pll_limits pll_cyclonev;

/* 0 on success, -1 if nothing in range reaches the target */
int pll_solve(unsigned long long target_hz,
	      const struct pll_limits *lim,
	      struct pll_config *out);

/*
 * The same, with the M counter's 32-bit fraction in play.
 *
 * Integer M/N/C gets coarse where the output is high and C is small: at 25 MHz
 * the C divider is only 24-64, so the reachable steps are wide and the worst
 * case in the 15 kHz band is 409 ppm -- a slipped frame every 41 seconds, which
 * is visible and defeats the point of Switchres computing an exact modeline.
 *
 * A fraction on M makes the VCO continuous rather than stepped, so the error
 * becomes the quantisation of k/2^32 -- parts per billion, not parts per
 * million. What it costs is that the fraction is dithered rather than exact:
 * the M divider alternates between two integers to average correctly, and that
 * dithering is periodic. Periodic phase noise correlates with pixel position,
 * which is the classic reason video PLLs stay integer.
 *
 * So this is not simply better. It trades a rate error you can measure for a
 * jitter pattern you might see. Which is why both solvers exist and the choice
 * is made per solve, not once at build time -- see pll_solve_best().
 */
int pll_solve_frac(unsigned long long target_hz,
		   const struct pll_limits *lim,
		   struct pll_config *out);

/*
 * Integer only when it is exact. Otherwise the fraction, always.
 *
 * This had a 50 ppm threshold, on the reasoning that a small rate error is not
 * worth the dithering a fraction brings. That is the wrong trade for what this
 * drives. A 15 kHz 2D game scrolls a whole screen horizontally at a constant
 * rate, and any mismatch between the source's frame rate and the display's
 * shows as a repeated or dropped frame -- a visible hitch in a smoothly moving
 * background, which is exactly the artefact these modelines exist to avoid.
 * 50 ppm is a slip every five and a half minutes. Dither is a noise floor;
 * a slipped frame is an event you see.
 *
 * So the fraction is taken whenever it is closer. Zero keeps the integer
 * solution only when it is already exact -- which every advertised mode is, so
 * the common cases still carry no dithering at all.
 */
#define PLL_FRAC_PPM_THRESHOLD  0

/*
 * Tell the solver whether the fabric has a fractional PLL. Read from CAPS bit
 * 2 at startup; off until then, so a build that never calls this stays on
 * integers rather than silently running 3% out.
 */
void pll_set_fractional(int available);

int pll_solve_best(unsigned long long target_hz,
		   const struct pll_limits *lim,
		   struct pll_config *out);

#endif
