/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * The LZ4 block decompressor, including malformed input.
 *
 * The blocks arrive over USB from whatever is at the other end, so the refusals
 * matter as much as the successes: a bad offset, or a length that runs past the
 * buffer, must return an error rather than walk off the end.
 */

#include <stdio.h>
#include <string.h>

#include "../lz4dec.h"

static int fails;

static void chk(const char *name, int ok)
{
	printf("  %-52s %s\n", name, ok ? "ok" : "FAIL");
	if (!ok)
		fails++;
}

int main(void)
{
	uint8_t out[256];
	long n;

	printf("LZ4 block decompression\n");

	/* token 0x50: five literals, no match */
	{
		const uint8_t b[] = { 0x50, 'H', 'e', 'l', 'l', 'o' };
		n = blitscrt_lz4_decompress(b, sizeof b, out, sizeof out);
		chk("literals only", n == 5 && !memcmp(out, "Hello", 5));
	}

	/* one literal 'A', then offset 1 and match 0+4: the run-length case,
	 * which is why the copy has to be byte at a time */
	{
		const uint8_t b[] = { 0x10, 'A', 0x01, 0x00 };
		n = blitscrt_lz4_decompress(b, sizeof b, out, sizeof out);
		chk("overlapping match encodes a run",
		    n == 5 && !memcmp(out, "AAAAA", 5));
	}

	/* literal length 15 plus an extension byte */
	{
		uint8_t b[22];
		int i;
		b[0] = 0xF0;
		b[1] = 5;                       /* 15 + 5 = 20 */
		for (i = 0; i < 20; i++)
			b[2 + i] = (uint8_t)('a' + i);
		n = blitscrt_lz4_decompress(b, sizeof b, out, sizeof out);
		chk("extended literal length", n == 20 && out[19] == 'a' + 19);
	}

	{
		const uint8_t b[] = { 0x10, 'A', 0x10, 0x00 };
		chk("offset before the buffer start is refused",
		    blitscrt_lz4_decompress(b, sizeof b, out, sizeof out) == -1);
	}

	{
		const uint8_t b[] = { 0xA0, 'x' };
		chk("literals past the input end are refused",
		    blitscrt_lz4_decompress(b, sizeof b, out, sizeof out) == -1);
	}

	{
		const uint8_t b[] = { 0x10, 'A', 0x00, 0x00 };
		chk("zero offset is refused",
		    blitscrt_lz4_decompress(b, sizeof b, out, sizeof out) == -1);
	}

	{
		const uint8_t b[] = { 0x50, 'H', 'e', 'l', 'l', 'o' };
		chk("output overrun is refused",
		    blitscrt_lz4_decompress(b, sizeof b, out, 3) == -1);
	}

	if (fails)
		printf("\nFAIL  %d checks\n", fails);
	else
		printf("\nPASS\n");
	return fails != 0;
}
