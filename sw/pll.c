/* SPDX-License-Identifier: MIT */
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
	.m_min = 1,   .m_max = 512,
	.n_min = 1,   .n_max = 512,
	.c_min = 1,   .c_max = 512,
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

	out->ops = 0;

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
