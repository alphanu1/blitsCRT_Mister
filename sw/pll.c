/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * pll.c -- solve Cyclone V PLL counters for an arbitrary pixel clock.
 *
 * This is what makes dynamic resolutions possible. A fixed mode list can have
 * its counters precomputed at synthesis time; Switchres generating a modeline
 * per game cannot. The device is handed a pixel clock in kHz on modeset and
 * has to reach it.
 *
 *   fVCO = fREF * M / N        must land inside the VCO band
 *   fPFD = fREF / N            must land inside the phase detector band
 *   fOUT = fVCO / C
 *
 * Finding three integers whose ratio approximates a real number is a
 * Diophantine problem with no closed form. A direct search over the counter
 * ranges is a few thousand integer operations, which is nothing on an 800MHz
 * A9 running once per modeset. Continued fractions would be faster and would
 * still need the constraint checks, so they are not worth the complexity here.
 *
 * The search is ordered so that the first exact hit wins and ties break toward
 * a higher VCO, which gives better jitter.
 */

#include <string.h>
#include "pll.h"

#include <stdlib.h>
#include <limits.h>

/*
 * Cyclone V limits. The VCO band is speed-grade dependent; these are the
 * conservative numbers for a -7 part. Widening them is safe only against the
 * datasheet for the exact device.
 */
const struct pll_limits pll_cyclonev = {
	.fin_hz     = 50000000ull,
	.vco_min_hz =   600000000ull,
	.vco_max_hz =  1600000000ull,
	.pfd_min_hz =     5000000ull,
	.pfd_max_hz =   325000000ull,
	/* 510, not 512. The reconfiguration encoding splits each counter into
	 * two eight-bit half-periods, so 255 + 255 is the ceiling. Solving for
	 * a divide the hardware cannot be told about is worse than not solving
	 * at all. */
	.m_min = 1,   .m_max = 510,
	.n_min = 1,   .n_max = 510,
	.c_min = 1,   .c_max = 510,
};

static unsigned long long absdiff(unsigned long long a, unsigned long long b)
{
	return a > b ? a - b : b - a;
}

int pll_solve(unsigned long long target_hz,
	      const struct pll_limits *lim,
	      struct pll_config *out)
{
	unsigned long long best_err = ULLONG_MAX;
	unsigned long long best_vco = 0;
	unsigned int n, c;
	int found = 0;

	if (!target_hz || !lim || !out)
		return -1;

	/*
	 * Clear the whole config, not just ops.
	 *
	 * This used to zero ops alone and leave everything else to be filled by
	 * the search, which was fine while every field was written. Adding the
	 * fractional numerator broke that silently: an integer solution never
	 * touches k, so it carried whatever the caller happened to have there
	 * and the reconfig sequence wrote a stray fraction to the PLL.
	 *
	 * An integer solve must leave k == 0, because that is what makes the
	 * same write sequence correct for both cores.
	 */
	memset(out, 0, sizeof *out);

	for (n = lim->n_min; n <= lim->n_max; n++) {
		unsigned long long pfd = lim->fin_hz / n;

		/* the phase detector sees fin/n and has its own band */
		if (lim->fin_hz % n)
			pfd = lim->fin_hz / n;      /* truncation is fine for the bound check */
		if (pfd < lim->pfd_min_hz)
			break;                       /* larger n only makes it smaller */
		if (pfd > lim->pfd_max_hz)
			continue;

		for (c = lim->c_min; c <= lim->c_max; c++) {
			/*
			 * Want fin*m/n == target*c, so m == target*c*n/fin.
			 * Try the two integers either side rather than
			 * sweeping m, which turns an O(m*n*c) search into
			 * O(n*c).
			 */
			unsigned long long num = target_hz * c * n;
			unsigned int m0 = (unsigned int)(num / lim->fin_hz);
			unsigned int k;

			for (k = 0; k < 2; k++) {
				unsigned int m = m0 + k;
				unsigned long long vco, fout, err;

				if (m < lim->m_min || m > lim->m_max)
					continue;

				vco = lim->fin_hz * m / n;
				if (vco < lim->vco_min_hz || vco > lim->vco_max_hz)
					continue;

				fout = vco / c;
				err  = absdiff(fout, target_hz);
				out->ops++;

				/* exact wins; otherwise closest, then higher VCO */
				if (err < best_err ||
				    (err == best_err && vco > best_vco)) {
					best_err = err;
					best_vco = vco;
					out->m = m;
					out->n = n;
					out->c = c;
					out->vco_hz = vco;
					out->actual_hz = fout;
					found = 1;
					if (err == 0 && vco >= lim->vco_max_hz / 2)
						goto done;
				}
			}
		}
	}

done:
	if (!found)
		return -1;

	out->target_hz = target_hz;
	out->error_hz  = (long long)out->actual_hz - (long long)target_hz;
	out->error_ppm = target_hz ? (out->error_hz * 1000000ll) /
				     (long long)target_hz : 0;
	return 0;
}

/*
 * Fractional-N: the same search, with a 32-bit fraction on M.
 *
 * The integer solver picks M, N and C and lives with whatever VCO that reaches.
 * Here the VCO is continuous, so the job inverts: choose N and C, work out the
 * exact M that would hit the target, and split it into an integer part and a
 * 32-bit fraction.
 *
 *   fout  = fin * (m + k/2^32) / (n * c)
 *   m+f   = fout * n * c / fin
 *   k     = round(f * 2^32)
 *
 * The residual is then only the rounding of k, which at 2^-32 of the VCO is
 * fractions of a hertz -- parts per billion. What limits the result in practice
 * is the VCO and PFD ranges, exactly as for the integer search.
 */
int pll_solve_frac(unsigned long long target_hz,
		   const struct pll_limits *lim,
		   struct pll_config *out)
{
	unsigned int n, c;
	unsigned long long best_err = ~0ull, best_vco = 0;
	int found = 0;

	if (!target_hz || !lim || !out)
		return -1;

	memset(out, 0, sizeof *out);

	for (n = lim->n_min; n <= lim->n_max; n++) {
		unsigned long long pfd = lim->fin_hz / n;

		if (pfd < lim->pfd_min_hz || pfd > lim->pfd_max_hz)
			continue;

		for (c = lim->c_min; c <= lim->c_max; c++) {
			/*
			 * The VCO this N and C would need. Work in a long
			 * double so the fraction survives: at 400 MHz a 2^-32
			 * step is 0.09 Hz, and a double's 53-bit mantissa
			 * carries that comfortably, but the intermediate
			 * products are large enough to be worth the headroom.
			 */
			long double vco_want = (long double)target_hz * c;
			long double m_want;
			unsigned long long m_int, k, vco, fout;

			if (vco_want < (long double)lim->vco_min_hz ||
			    vco_want > (long double)lim->vco_max_hz)
				continue;

			m_want = vco_want * n / (long double)lim->fin_hz;
			m_int  = (unsigned long long)m_want;

			if (m_int < lim->m_min || m_int > lim->m_max)
				continue;

			k = (unsigned long long)
			    ((m_want - (long double)m_int) * 4294967296.0L + 0.5L);

			/* Rounding up can carry into the integer part. */
			if (k >= 4294967296ull) {
				k = 0;
				m_int++;
				if (m_int > lim->m_max)
					continue;
			}

			/*
			 * Keep the fraction away from the ends.
			 *
			 * AN-661: "For optimum performance, set the MFRAC value
			 * between 0.05 and 0.95." A delta-sigma modulator is at
			 * its worst near 0 and 1 -- the dither pattern repeats
			 * over a long period and its energy concentrates into a
			 * few spurs rather than spreading, which on a display is
			 * the difference between a noise floor and visible
			 * structure.
			 *
			 * Nothing is lost by refusing them. A fraction below
			 * 0.05 means an integer M is already within 5% of a
			 * counter step, so pll_solve reaches it about as well;
			 * and the search runs over every N and C, so another
			 * combination almost always lands in the middle of the
			 * range.
			 */
			if (k != 0) {
				long double f = (long double)k / 4294967296.0L;
				if (f < 0.05L || f > 0.95L)
					continue;
			}

			out->ops++;

			/* What that actually reaches, back through the same
			 * arithmetic the hardware does. */
			vco = (unsigned long long)
			      ((long double)lim->fin_hz *
			       ((long double)m_int + (long double)k / 4294967296.0L)
			       / n + 0.5L);
			fout = (unsigned long long)
			       ((long double)vco / c + 0.5L);

			{
				unsigned long long err = fout > target_hz
						       ? fout - target_hz
						       : target_hz - fout;

				if (err < best_err ||
				    (err == best_err && vco > best_vco)) {
					best_err = err;
					best_vco = vco;
					out->m = (unsigned int)m_int;
					out->n = n;
					out->c = c;
					out->k = (unsigned int)k;
					out->vco_hz = vco;
					out->actual_hz = fout;
					found = 1;
				}
			}
		}
	}

	if (!found)
		return -1;

	out->target_hz = target_hz;
	out->error_hz  = (long long)out->actual_hz - (long long)target_hz;
	out->error_ppm = target_hz ? (out->error_hz * 1000000ll) /
				     (long long)target_hz : 0;
	return 0;
}

/*
 * Integer where it is good enough, fractional where it is not.
 *
 * The fraction is taken whenever it is closer, and the threshold is zero -- so
 * an integer solution is kept only when it is already exact.
 *
 * Fractional-N dithers the M divider between two integers to average the
 * fraction, and that dithering is periodic, which is why video PLLs
 * traditionally stay integer. But the thing this drives is a 15 kHz display
 * showing 2D games that scroll a whole screen at a constant rate, and a rate
 * mismatch there is a repeated or dropped frame -- a hitch in a smoothly moving
 * background. Dither is a noise floor; a slipped frame is an event you see.
 *
 * Every mode the fabric advertises solves to 0 ppm on integers, so the common
 * cases still never reach the fractional path.
 */
/*
 * Whether the fabric has a fractional PLL fitted.
 *
 * Off until the daemon reads CAPS and says otherwise, because getting this
 * wrong is silent: on an integer core the K write is ignored, so a fractional
 * solution runs the integer part of M alone -- 6.327 MHz where 6.518 was asked
 * for -- and nothing reports it. Defaulting to integer means a wrong guess
 * costs accuracy, not correctness.
 */
static int pll_have_frac;

void pll_set_fractional(int available)
{
	pll_have_frac = available ? 1 : 0;
}

int pll_solve_best(unsigned long long target_hz,
		   const struct pll_limits *lim,
		   struct pll_config *out)
{
	struct pll_config frac;
	long long ppm;

	if (!pll_have_frac)
		return pll_solve(target_hz, lim, out);

	if (pll_solve(target_hz, lim, out) < 0)
		return pll_solve_frac(target_hz, lim, out);

	ppm = out->error_ppm < 0 ? -out->error_ppm : out->error_ppm;
	if (ppm <= PLL_FRAC_PPM_THRESHOLD)
		return 0;

	if (pll_solve_frac(target_hz, lim, &frac) == 0) {
		long long fppm = frac.error_ppm < 0 ? -frac.error_ppm
						    : frac.error_ppm;
		if (fppm < ppm) {
			frac.ops += out->ops;
			*out = frac;
		}
	}
	return 0;
}
