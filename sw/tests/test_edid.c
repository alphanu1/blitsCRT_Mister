/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * The synthesised EDID.
 *
 * A malformed block is worse than none -- a host that rejects it falls back to
 * "unknown" anyway, and one that half-accepts it may take timings from it. So
 * the structural checks matter as much as the name.
 */

#include <stdio.h>
#include <string.h>

#include "../edid.h"

static int fails;

static void chk(const char *name, int ok)
{
	printf("  %-52s %s\n", name, ok ? "ok" : "FAIL");
	if (!ok)
		fails++;
}

int main(void)
{
	uint8_t e[BLITSCRT_EDID_LEN];
	unsigned sum = 0;
	size_t n;
	int i;

	printf("EDID\n");

	n = blitscrt_edid_build(e, sizeof e, "blitsCRT", 1, 15, 16, 47, 63, 32000);
	chk("128 bytes", n == BLITSCRT_EDID_LEN);

	chk("header", e[0] == 0x00 && e[1] == 0xff && e[6] == 0xff && e[7] == 0x00);

	for (i = 0; i < BLITSCRT_EDID_LEN; i++)
		sum += e[i];
	chk("checksum sums to zero mod 256", (sum & 0xff) == 0);

	chk("version 1.4", e[18] == 1 && e[19] == 4);

	/* No timings, deliberately: the GUD mode list is the only source. */
	chk("no established timings", e[35] == 0 && e[36] == 0 && e[37] == 0);
	chk("no standard timings", e[38] == 0x01 && e[39] == 0x01 &&
				   e[52] == 0x01 && e[53] == 0x01);
	chk("no detailed timing descriptor",
	    e[54] == 0 && e[55] == 0 && e[56] == 0 &&
	    e[72] == 0 && e[73] == 0 && e[74] == 0);

	chk("descriptor 1 is a monitor name", e[57] == 0xfc);
	chk("the name reads back", !memcmp(e + 59, "blitsCRT", 8));
	chk("the name is terminated", e[67] == 0x0a);

	chk("descriptor 2 is range limits", e[75] == 0xfd);
	chk("vertical 47-63 Hz", e[77] == 47 && e[78] == 63);
	chk("horizontal 15-16 kHz", e[79] == 15 && e[80] == 16);
	chk("max clock in 10 MHz units, rounded up", e[81] == 4);

	chk("no extension blocks", e[126] == 0);

	/* A buffer too small must be refused rather than half-filled. */
	chk("a short buffer is refused",
	    blitscrt_edid_build(e, 64, "x", 1, 15, 16, 47, 63, 32000) == 0);

	/* Name-only: the range descriptor must not be there at all, since that
	 * is the half a host was seen to act on. */
	blitscrt_edid_build(e, sizeof e, "blitsCRT", 0, 15, 16, 47, 63, 32000);
	chk("name-only omits the range limits", e[75] == 0x10);
	chk("name-only still names the display", e[57] == 0xfc &&
	    !memcmp(e + 59, "blitsCRT", 8));
	for (sum = 0, i = 0; i < BLITSCRT_EDID_LEN; i++)
		sum += e[i];
	chk("name-only checksum is still valid", (sum & 0xff) == 0);

	if (fails)
		printf("\nFAIL  %d checks\n", fails);
	else
		printf("\nPASS\n");
	return fails != 0;
}
