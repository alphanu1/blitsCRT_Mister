/* Exercise the PLL solver against real 15kHz pixel clocks. */
#include <stdio.h>
#include <string.h>
#include "../pll.h"

struct tc { const char *name; unsigned long long hz; };

static const struct tc cases[] = {
	/* the two modes M1 ships */
	{ "320x240p60      ",  6400000ull },
	{ "640x480i60      ", 12600000ull },

	/* console and arcade timings Switchres would generate */
	{ "NES 256x240     ",  5369318ull },
	{ "SNES 256x224    ",  5369318ull },
	{ "Genesis 320x224 ",  6710886ull },
	{ "CPS1 384x224    ",  8000000ull },
	{ "Neo Geo 320x224 ",  6000000ull },
	{ "PC Engine 256p  ",  7159090ull },
	{ "Amiga PAL 320   ",  7093790ull },
	{ "C64 PAL         ",  7881984ull },
	{ "MAME 15.734k    ",  6712000ull },
	{ "awkward prime   ",  6700417ull },

	/* boundaries */
	{ "very low  2 MHz ",  2000000ull },
	{ "high     32 MHz ", 32000000ull },
};

int main(void)
{
	unsigned long worst_ops = 0;
	long long worst_ppm = 0;
	int fails = 0;
	size_t i;

	printf("%-18s %10s  %4s %4s %4s  %9s %12s %8s %7s\n",
	       "mode", "target", "M", "N", "C", "VCO MHz", "actual", "err ppm", "ops");
	printf("--------------------------------------------------------------------------------------\n");

	for (i = 0; i < sizeof(cases)/sizeof(cases[0]); i++) {
		struct pll_config p;
		memset(&p, 0, sizeof p);

		if (pll_solve(cases[i].hz, &pll_cyclonev, &p) < 0) {
			printf("%-18s %10llu  NO SOLUTION\n", cases[i].name, cases[i].hz);
			fails++;
			continue;
		}

		printf("%-18s %10llu  %4u %4u %4u  %9.3f %12llu %8lld %7lu\n",
		       cases[i].name, cases[i].hz, p.m, p.n, p.c,
		       p.vco_hz / 1e6, p.actual_hz, p.error_ppm, p.ops);

		if (p.vco_hz < pll_cyclonev.vco_min_hz ||
		    p.vco_hz > pll_cyclonev.vco_max_hz) {
			printf("    FAIL VCO out of band\n");
			fails++;
		}
		if (p.error_ppm > 200 || p.error_ppm < -200) {
			printf("    FAIL error above 200 ppm\n");
			fails++;
		}
		if (p.ops > worst_ops) worst_ops = p.ops;
		if (p.error_ppm > worst_ppm)  worst_ppm = p.error_ppm;
		if (-p.error_ppm > worst_ppm) worst_ppm = -p.error_ppm;
	}

	printf("\nworst error %lld ppm, worst search %lu candidate evaluations\n",
	       worst_ppm, worst_ops);
	printf("%s\n", fails ? "FAIL" : "PASS");
	return fails ? 1 : 0;
}
