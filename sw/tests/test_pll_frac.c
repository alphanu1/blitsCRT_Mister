/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * The fractional-N solver, and when it is preferred over the integer one.
 *
 * Integer M/N/C gets coarse where the output is high and C is small: the worst
 * case in the 15 kHz band is 409 ppm at 12.494 MHz, and 880 ppm at 24.978 in
 * the 31 kHz band. Those are hardware limits, not search failures -- an
 * exhaustive sweep finds the same answers.
 *
 * A 32-bit fraction on M makes the VCO continuous, so the residual becomes the
 * quantisation of k/2^32 rather than the spacing of integer ratios.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "pll.h"

static int fails;
static void check(const char *name, int cond)
{
	printf("  %-52s %s\n", name, cond ? "ok" : "FAIL");
	if (!cond) fails++;
}

int main(void)
{
	struct pll_config i, f, b;
	unsigned long long t;
	double worst_i = 0, worst_f = 0;
	unsigned n = 0;

	printf("fractional-N solver\n");

	/* The two cases MEGAFUNCTIONS.md records as the hardware limit. */
	check("12.494 MHz is 409 ppm out on integers",
	      pll_solve(12494000, &pll_cyclonev, &i) == 0 &&
	      llabs(i.error_ppm) >= 400);
	check("and exact with a fraction",
	      pll_solve_frac(12494000, &pll_cyclonev, &f) == 0 &&
	      f.error_ppm == 0 && f.k != 0);

	check("24.978 MHz is 880 ppm out on integers",
	      pll_solve(24978000, &pll_cyclonev, &i) == 0 &&
	      llabs(i.error_ppm) >= 800);
	check("and exact with a fraction",
	      pll_solve_frac(24978000, &pll_cyclonev, &f) == 0 &&
	      f.error_ppm == 0);

	/* An exact integer clock must not take the fraction: dithering costs
	 * jitter, and there is no error to remove. */
	check("12.600 MHz solves exactly on integers",
	      pll_solve(12600000, &pll_cyclonev, &i) == 0 && i.error_ppm == 0);
	check("so the best-of solver keeps the integer, k = 0",
	      pll_solve_best(12600000, &pll_cyclonev, &b) == 0 &&
	      b.k == 0 && b.error_ppm == 0);

	/* An awkward one must take it. */
	check("12.494 MHz takes the fraction instead",
	      pll_solve_best(12494000, &pll_cyclonev, &b) == 0 &&
	      b.k != 0 && llabs(b.error_ppm) < 50);

	/* The whole band, not just the corners. */
	printf("\nsweeping both bands in 1 kHz steps\n");
	for (t = 5000000; t <= 28000000; t += 1000) {
		double ai, af;

		if (pll_solve(t, &pll_cyclonev, &i) < 0) continue;
		if (pll_solve_frac(t, &pll_cyclonev, &f) < 0) continue;
		ai = (double)llabs(i.error_ppm);
		af = (double)llabs(f.error_ppm);
		if (ai > worst_i) worst_i = ai;
		if (af > worst_f) worst_f = af;
		n++;
	}
	printf("  %u clocks, 5-28 MHz\n", n);
	printf("  worst integer     %4.0f ppm\n", worst_i);
	printf("  worst fractional  %4.0f ppm\n", worst_f);
	check("the integer worst case is the documented one", worst_i > 400);
	check("the fraction reaches every clock in both bands", worst_f == 0);

	/* k must fit what the hardware carries: fractional_cout(32). */
	check("k stays inside 32 bits",
	      pll_solve_frac(12494000, &pll_cyclonev, &f) == 0 &&
	      (unsigned long long)f.k < 4294967296ull);

	printf("\n%s\n", fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
