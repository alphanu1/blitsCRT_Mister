/* SPDX-License-Identifier: MIT */
/*
 * main.c -- blitscrtd, the GUD device daemon.
 *
 * Brings up the fabric, hands the mode list to the GUD layer, and runs the
 * FunctionFS event loop. Without a fabric it still answers the protocol, which
 * makes it possible to test enumeration against a real host before the SDRAM
 * path exists.
 */

#define _GNU_SOURCE
#include "device.h"
#include "fabric.h"
#include "gadget.h"
#include <unistd.h>
#include "blitscrt_regs.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static struct blitscrt_gadget *g_gadget;

static void on_signal(int sig)
{
	(void)sig;
	blitscrt_gadget_stop(g_gadget);
}

/* Fabric-only loop: no USB gadget, just keep the heartbeat ticking and the
 * overlay live. This is the M2 proof on a stock MiSTer kernel, which has
 * /dev/mem but not the dwc2/FunctionFS the gadget needs. */
static volatile int g_run = 1;
static void on_stop(int sig) { (void)sig; g_run = 0; }

static int run_no_gadget(struct blitscrt_dev *dev)
{
	signal(SIGINT,  on_stop);
	signal(SIGTERM, on_stop);
	fprintf(stderr, "blitscrtd: fabric-only mode, heartbeat running\n");
	blitscrt_dev_on_host(dev, 0);            /* test card, no host */
	while (g_run) {
		blitscrt_dev_heartbeat(dev);     /* bump the fabric watchdog */
		usleep(200000);                  /* ~5 Hz, well inside the timeout */
	}
	fprintf(stderr, "blitscrtd: stopping\n");
	return 0;
}

int main(int argc, char **argv)
{
	const char *ffs = "/dev/ffs-blitscrt";
	int no_gadget = 0;
	int i;
	struct blitscrt_dev dev;
	struct blitscrt_fabric *fab;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--no-gadget")) no_gadget = 1;
		else ffs = argv[i];
	}

	fab = blitscrt_fabric_open();
	if (!fab)
		fprintf(stderr, "blitscrtd: no fabric, running protocol only\n");
	else
		fprintf(stderr, "blitscrtd: fabric v%u.%u\n",
			blitscrt_fabric_read(fab, BLITSCRT_REG_VERSION) >> 16,
			blitscrt_fabric_read(fab, BLITSCRT_REG_VERSION) & 0xffff);

	blitscrt_dev_init(&dev, fab);
	blitscrt_dev_on_host(&dev, 0);   /* test card until a host turns up */

	fprintf(stderr, "blitscrtd: advertising %u modes\n", dev.n_modes);

	if (no_gadget) {
		int rc;
		if (!fab) {
			/* Our core is not loaded (no BCRT ID over the bridge), so
			 * there is no fabric to drive. Exit quietly -- this runs
			 * from user-startup on every MiSTer boot, including when a
			 * different core or the menu is active. */
			fprintf(stderr, "blitscrtd: blitsCRT core not loaded, nothing to do\n");
			return 0;
		}
		rc = run_no_gadget(&dev);
		blitscrt_fabric_close(fab);
		return rc;
	}

	g_gadget = blitscrt_gadget_open(ffs, &dev);
	if (!g_gadget) {
		fprintf(stderr, "blitscrtd: cannot open %s\n", ffs);
		fprintf(stderr, "           is the gadget mounted? see tools/gadget-setup.sh\n");
		blitscrt_fabric_close(fab);
		return 1;
	}

	signal(SIGINT,  on_signal);
	signal(SIGTERM, on_signal);

	blitscrt_gadget_run(g_gadget);

	fprintf(stderr, "blitscrtd: %lu modesets, %lu rejected, %lu flushes\n",
		dev.stat_modeset, dev.stat_rejected, dev.stat_flush);

	blitscrt_gadget_close(g_gadget);
	blitscrt_fabric_close(fab);
	return 0;
}
