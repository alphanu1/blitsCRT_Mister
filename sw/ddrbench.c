/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * blitscrt-ddrbench -- measure host-side write bandwidth into the DDR3 window
 * the fabric will read scanout from.
 *
 * This is the number M3c rests on, and it is the one that can invalidate the
 * design, so it gets measured before any of it is built.
 *
 * The argument: pixels arriving over USB are already in DDR3, put there by the
 * gadget. If scanout memory is also in DDR3 then the fabric comes to the pixels
 * over f2sdram and software never pushes a pixel across a bridge at all. Every
 * alternative -- on-chip memory, the SDRAM module -- has the ARM copying pixels
 * back out of DDR3 and through a bridge, which is work that need not happen.
 *
 * The catch: f2sdram ports reach the SDRAM controller directly and are not
 * coherent with the A9's caches. So the region software writes has to be mapped
 * uncached, and uncached streaming stores on a Cortex-A9 are not fast. If this
 * cannot clear the USB 2.0 bulk ceiling of roughly 35 MB/s then zero-copy into
 * an uncached window is the wrong plan, and the answer becomes a cached mapping
 * with explicit cache maintenance -- which userspace cannot do on ARM without a
 * kernel helper, so it would mean a small module or a CMA/dmabuf node.
 *
 * Reserve the window first, by adding mem= to bootargs in tools/blitsenv.txt:
 *
 *     mem=992M      leaves 32 MB at 0x3E000000 that Linux will not touch
 *
 * Then:
 *
 *     blitscrt-ddrbench 0x3E000000 8192
 *
 * Reading is measured too, but writing is what matters -- the fabric does the
 * reading and it does not go through this path.
 */

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <errno.h>
#include <sys/mman.h>

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}

/* Enough repeats that a slow path still runs long enough to time honestly. */
static int reps_for(size_t bytes)
{
	int r = (int)(64u * 1024u * 1024u / (bytes ? bytes : 1));
	return r < 4 ? 4 : (r > 4096 ? 4096 : r);
}

static void report(const char *what, size_t bytes, int reps, double secs)
{
	double mb = (double)bytes * reps / 1e6;
	printf("  %-28s %7.2f MB/s   (%d x %zu KB in %.3f s)\n",
	       what, secs > 0 ? mb / secs : 0.0, reps, bytes / 1024, secs);
}

int main(int argc, char **argv)
{
	unsigned long phys;
	size_t span, i;
	int fd, reps;
	volatile uint8_t *win;
	uint8_t *src;
	double t0;
	int bad = 0;

	if (argc != 3) {
		fprintf(stderr,
			"usage: %s <phys_base> <size_kb>\n"
			"  e.g. %s 0x3E000000 8192\n"
			"Reserve the region first with mem= in bootargs, or this\n"
			"will be writing over memory Linux is using.\n",
			argv[0], argv[0]);
		return 2;
	}
	phys = strtoul(argv[1], NULL, 0);
	span = (size_t)strtoul(argv[2], NULL, 0) * 1024;

	fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) {
		fprintf(stderr, "open /dev/mem: %s\n", strerror(errno));
		return 1;
	}

	/* O_SYNC is what makes this mapping uncached, which is the case that
	 * matters: it is what a coherent-with-f2sdram mapping has to be. */
	win = mmap(NULL, span, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
	if (win == MAP_FAILED) {
		fprintf(stderr, "mmap 0x%lx +%zu: %s\n", phys, span, strerror(errno));
		close(fd);
		return 1;
	}

	src = malloc(span);
	if (!src) { fprintf(stderr, "out of memory\n"); return 1; }
	for (i = 0; i < span; i++) src[i] = (uint8_t)(i * 7 + 1);

	printf("uncached window at 0x%08lx, %zu KB\n\n", phys, span / 1024);

	/* Does it actually hold what is written? A window that reads back wrong
	 * is not slow, it is unusable, and that has to be known before any
	 * throughput number means anything. */
	memcpy((void *)win, src, span);
	for (i = 0; i < span; i++)
		if (win[i] != src[i]) { bad = 1; break; }
	printf("  readback %s%s\n\n", bad ? "MISMATCH at offset " : "verified",
	       bad ? "" : "");
	if (bad) {
		printf("  first bad byte at 0x%zx: wrote 0x%02x read 0x%02x\n",
		       i, src[i], win[i]);
		printf("  the window is not usable; check mem= actually reserved it\n");
	}

	printf("write, host -> DDR3 (what the daemon does):\n");

	reps = reps_for(span);
	t0 = now();
	for (i = 0; i < (size_t)reps; i++) memcpy((void *)win, src, span);
	report("memcpy", span, reps, now() - t0);

	t0 = now();
	for (i = 0; i < (size_t)reps; i++) memset((void *)win, (int)i, span);
	report("memset", span, reps, now() - t0);

	{
		volatile uint32_t *w32 = (volatile uint32_t *)win;
		size_t n = span / 4, k;
		t0 = now();
		for (i = 0; i < (size_t)reps; i++)
			for (k = 0; k < n; k++) w32[k] = (uint32_t)k;
		report("32-bit stores", span, reps, now() - t0);
	}

	/* A short rect row is the realistic case: GUD damage is usually narrow,
	 * and a per-row memcpy of a few hundred bytes pays setup cost that a
	 * whole-buffer copy amortises away. */
	{
		size_t row = 1280;              /* 640 px RGB565 */
		size_t rows = span / row, k;
		int rr = reps_for(span);
		t0 = now();
		for (i = 0; i < (size_t)rr; i++)
			for (k = 0; k < rows; k++)
				memcpy((void *)(win + k * row), src + k * row, row);
		report("memcpy in 1280B rows", rows * row, rr, now() - t0);
	}

	printf("\nread, DDR3 -> host (not on the scanout path; the fabric reads):\n");
	reps = reps_for(span);
	t0 = now();
	for (i = 0; i < (size_t)reps; i++) memcpy(src, (void *)win, span);
	report("memcpy", span, reps, now() - t0);

	printf("\nwhat the write figure has to cover, full-frame at 60 Hz:\n");
	printf("  320x240 RGB565    9.2 MB/s\n");
	printf("  320x480 RGB565   18.4 MB/s\n");
	printf("  640x480 RGB565   36.9 MB/s   <- USB 2.0 bulk is ~35 MB/s\n");
	printf("  640x480 RGB888   55.3 MB/s\n");
	printf("\nDamage rects mean the real load sits well under these. Clearing\n");
	printf("~35 MB/s means the uncached window keeps up with anything USB can\n");
	printf("deliver, and zero-copy into it is the right plan.\n");

	munmap((void *)win, span);
	free(src);
	close(fd);
	return bad ? 1 : 0;
}
