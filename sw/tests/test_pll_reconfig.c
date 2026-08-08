/* SPDX-License-Identifier: GPL-2.0-or-later */
/* Counter encoding has to round-trip and the halves have to sum to the divide,
 * or the PLL comes up at the wrong frequency with no error anywhere. */
#include <stdio.h>
#include <string.h>
#include "../pll_reconfig.h"
#include "../modes.h"

static int fails;

static void check(const char *what, int cond)
{
	if (!cond) { printf("  FAIL %s\n", what); fails++; }
}

int main(void)
{
	unsigned int d;

	printf("counter encoding\n");
	printf("  %6s %6s %5s %5s %6s %4s  %10s\n",
	       "divide", "high", "low", "sum", "bypass", "odd", "raw");

	for (d = 1; d <= PLL_DIVIDE_MAX; d++) {
		struct pll_counter c = pll_encode_counter(d);
		unsigned int sum = c.high + c.low;

		if (d <= 1) {
			check("divide 1 bypasses", c.bypass == 1);
		} else {
			check("halves sum to the divide", sum == d);
			check("odd duty set only for odd divides",
			      c.odd_duty == (d & 1));
			check("high is the longer half",
			      c.high >= c.low && c.high - c.low <= 1);
			check("bypass clear above 1", c.bypass == 0);
		}
		check("round trips", pll_decode_counter(c.raw) == (d <= 1 ? 1 : d));
		check("halves fit in a byte", c.high <= 255 && c.low <= 255);

		if (d == 1 || d == 2 || d == 63 || d == 64 || d == 125 ||
		    d == 128 || d == 250 || d == 509 || d == 510)
			printf("  %6u %6u %5u %5u %6u %4u  0x%08X\n",
			       d, c.high, c.low, sum, c.bypass, c.odd_duty, c.raw);
	}

	printf("\nwrite sequences for the advertised modes\n");
	{
		struct { const char *n; uint32_t khz; } modes[] = {
			{ "640x480i60", 12600 }, { "640x576i50", 12500 },
			{ "320x240p60",  6300 }, { "320x288p50",  6250 },
			{ "256x224 arcade", 5369 },
		};
		size_t i;

		for (i = 0; i < sizeof modes / sizeof modes[0]; i++) {
			struct pll_config p;
			struct pll_reconfig_seq q;
			unsigned int j;

			if (pll_solve((unsigned long long)modes[i].khz * 1000ull,
				      &pll_cyclonev, &p) < 0) {
				printf("  %-16s no PLL solution\n", modes[i].n);
				fails++;
				continue;
			}
			check("sequence builds", pll_reconfig_build(&p, 0, &q) == 0);
			/* MODE, N, M, K, C, START. K carries the fractional
			 * numerator and is written even when it is zero, so the
			 * same sequence drives an integer or a fractional PLL. */
			check("six writes", q.count == 6);
			check("mode word first", q.w[0].addr == PLL_RECONFIG_MODE);
			check("start last", q.w[q.count-1].addr == PLL_RECONFIG_START);
			check("N round trips",
			      pll_decode_counter(q.w[1].data) == p.n);
			check("M round trips",
			      pll_decode_counter(q.w[2].data) == p.m);
			check("K carries the fraction",
			      q.w[3].addr == PLL_RECONFIG_K && q.w[3].data == p.k);
			check("C round trips",
			      pll_decode_counter(q.w[4].data & 0x3ffff) == p.c);

			printf("  %-16s M=%-3u N=%-2u C=%-3u  ", modes[i].n, p.m, p.n, p.c);
			for (j = 1; j < q.count - 1; j++)
				printf("[%u]=0x%05X ", q.w[j].addr, q.w[j].data);
			printf("\n");
		}
	}

	printf("\nrejections\n");
	{
		struct pll_config p; struct pll_reconfig_seq q;
		memset(&p, 0, sizeof p);
		check("zero counters refused", pll_reconfig_build(&p, 0, &q) < 0);
		p.m = 600; p.n = 1; p.c = 1;
		check("M past the ceiling refused", pll_reconfig_build(&p, 0, &q) < 0);
		p.m = 16; p.n = 1; p.c = 125;
		check("valid config accepted", pll_reconfig_build(&p, 0, &q) == 0);
		check("bad C index refused", pll_reconfig_build(&p, 18, &q) < 0);
		p.m = 16; p.n = 1; p.c = 511;
		check("divide past 510 refused", pll_reconfig_build(&p, 0, &q) < 0);
		check("511 does not encode", pll_encode_counter(511).divide == 0);
	}

	printf("\n%s\n", fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
