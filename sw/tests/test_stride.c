#include <stdio.h>
#include "blitscrt_regs.h"
/* The padding rule, checked arithmetically. The real call needs a fabric. */
static unsigned pad(unsigned w, unsigned bpp)
{
	return (w * bpp + BLITSCRT_F2SDRAM_BEAT - 1u) &
	       ~(BLITSCRT_F2SDRAM_BEAT - 1u);
}
int main(void)
{
	unsigned w, bad = 0;
	printf("scanout stride padding\n");
	for (w = 1; w <= 1280; w++) {
		unsigned s = pad(w, 2);
		if (s % BLITSCRT_F2SDRAM_BEAT) { bad++; continue; }
		if (s < w * 2) bad++;                   /* must still hold the line */
		if (s - w * 2 >= BLITSCRT_F2SDRAM_BEAT) bad++;  /* no more than needed */
	}
	printf("  %-52s %s\n", "every width 1..1280 gives a beat-aligned stride",
	       bad ? "FAIL" : "ok");
	printf("  %-52s %s\n", "648 needs no padding", pad(648,2) == 1296 ? "ok" : "FAIL");
	printf("  %-52s %s\n", "642 is padded to the next beat", pad(642,2) == 1288 ? "ok" : "FAIL");
	printf("  %-52s %s\n", "an odd width still works", pad(321,2) == 648 ? "ok" : "FAIL");
	printf("\n%s\n", bad ? "FAIL" : "PASS");
	return bad ? 1 : 0;
}
