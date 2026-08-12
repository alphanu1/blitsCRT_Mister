/* SPDX-License-Identifier: GPL-2.0-or-later */
#ifndef BLITSCRT_DEVICE_H
#define BLITSCRT_DEVICE_H

#include <time.h>
#include <stdint.h>
#include <stddef.h>
#include "gud.h"
#include "modes.h"

#define BLITSCRT_MAX_MODES  32

struct blitscrt_fabric;    /* opaque, see fabric.h */

/* How long the display stays black before the test card returns. Long enough
 * that a mode change never reaches it -- those are over in milliseconds -- and
 * short enough to answer "is it still alive?" without a wait. */
#define BLITSCRT_TESTCARD_DELAY_MS  3000

struct blitscrt_dev {
	struct blitscrt_fabric *fabric;      /* NULL runs headless, for tests */
	int gadget_bound;                    /* UDC bound; the user button toggles it */

	struct blitscrt_mode modes[BLITSCRT_MAX_MODES];
	unsigned int         n_modes;
	int                  modes_changed;  /* raises CHANGED on next status read */

	uint8_t  last_status;                /* answer to GET_STATUS */
	uint8_t  format;
	int      host_attached;
	int      controller_enabled;
	/* Test card timeout: when the display last had something driving it, and
	 * whether the card is currently up. */
	struct timespec idle_since;
	int      testcard_shown;
	uint32_t heartbeat;
	int      display_enabled;

	struct blitscrt_mode    pending_mode; /* from SET_STATE_CHECK */
	struct blitscrt_timing  pending_timing;
	int                     pending_valid;

	struct blitscrt_mode    active_mode;
	struct blitscrt_timing  active_timing;
	int                     active_valid;

	struct gud_set_buffer_req buffer;     /* rect for the next bulk transfer */
	int                       buffer_valid;

	unsigned long stat_modeset, stat_flush, stat_rejected;
};

void blitscrt_dev_init(struct blitscrt_dev *d, struct blitscrt_fabric *f);

/* Populate the advertised mode list. */
void blitscrt_modelist_reset(struct blitscrt_dev *d);
int  blitscrt_modelist_add(struct blitscrt_dev *d, const struct blitscrt_mode *m);
void blitscrt_modelist_defaults(struct blitscrt_dev *d);

/*
 * Host attach and detach. On detach the fabric falls back to the test card,
 * because stale pixels scanning out after the cable is pulled looks
 * exactly like a crash.
 */
void blitscrt_dev_on_host(struct blitscrt_dev *d, int attached);

/* Refresh the overlay from current state. Safe with no fabric. */
void blitscrt_dev_refresh_overlay(struct blitscrt_dev *d);

/* Call periodically from the main loop; keeps the fabric's HPS-alive watchdog
 * fed and pushes USB host state to the fabric banner. */
void blitscrt_dev_heartbeat(struct blitscrt_dev *d);

/*
 * Handle one control request.
 *
 * For device-to-host, writes up to buflen bytes into buf and returns the
 * length. For host-to-device, data holds the payload. Returns the number of
 * bytes to send, 0 for a request with no data stage, or negative to stall.
 */
int blitscrt_handle_ctrl(struct blitscrt_dev *d,
			 uint8_t bRequest, uint16_t wValue, uint16_t wIndex,
			 const void *data, uint16_t data_len,
			 void *buf, size_t buflen);

#endif
