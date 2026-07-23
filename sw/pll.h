/* SPDX-License-Identifier: MIT */
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

#endif
