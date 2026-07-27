/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * device.c -- the GUD control endpoint, independent of how bytes reach it.
 *
 * Keeping this free of USB lets the whole protocol surface be exercised in a
 * test harness. The FunctionFS layer in gadget.c does nothing but move bytes
 * between ep0 and here.
 *
 * The interesting request is SET_STATE_CHECK. GUD hands over a complete DRM
 * mode, and nothing obliges the host to pick one the device advertised --
 * Switchres exists to synthesise new ones per game. So the device validates
 * and answers, and modes.c decides what a 15kHz CRT will survive.
 */

#include "device.h"
#include "fabric.h"
#include "blitscrt_regs.h"

#include <stdio.h>
#include <string.h>

void blitscrt_dev_init(struct blitscrt_dev *d, struct blitscrt_fabric *f)
{
	memset(d, 0, sizeof *d);
	d->fabric      = f;
	d->last_status = GUD_STATUS_OK;
	d->format      = GUD_PIXEL_FORMAT_RGB565;
	blitscrt_modelist_defaults(d);
}

void blitscrt_modelist_reset(struct blitscrt_dev *d)
{
	d->n_modes = 0;
	d->modes_changed = 1;
}

int blitscrt_modelist_add(struct blitscrt_dev *d, const struct blitscrt_mode *m)
{
	struct blitscrt_timing t;

	if (d->n_modes >= BLITSCRT_MAX_MODES)
		return -1;
	/* never advertise something we would refuse to set */
	if (blitscrt_mode_check(m, &blitscrt_limits_15khz, &t) != BLITSCRT_MODE_OK)
		return -1;

	d->modes[d->n_modes++] = *m;
	d->modes_changed = 1;
	return 0;
}

void blitscrt_modelist_defaults(struct blitscrt_dev *d)
{
	struct blitscrt_mode m;

	blitscrt_modelist_reset(d);

	/*
	 * Advertised first and flagged PREFERRED, which is what a host picks
	 * on first connect. 480i is a standard SD format, so anything on the
	 * other end recognises it, and a 15kHz CRT takes it happily.
	 *
	 * The 320-wide modes are exactly half their 640-wide partners, and the
	 * counters fall out of the same VCO:
	 *
	 *   640x480i60  12.600 MHz  VCO 1575  C=125   NTSC pair
	 *   320x240p60   6.300 MHz  VCO 1575  C=250
	 *   640x576i50  12.500 MHz  VCO  800  C=64    PAL pair
	 *   320x288p50   6.250 MHz  VCO  800  C=128
	 *
	 * Two VCOs cover all four, and within a VCO the 640 and 320 modes are
	 * one counter apart. All four solve to 0 ppm.
	 */

	/* 640x480i60 -- 15.750 kHz, 60.00 Hz field, 525 lines */
	blitscrt_mode_from_modeline(&m, 12600, 640, 664, 724, 800,
				    480, 486, 492, 525,
				    BLITSCRT_MF_INTERLACE |
				    BLITSCRT_MF_NHSYNC | BLITSCRT_MF_NVSYNC |
				    BLITSCRT_MF_PREFERRED);
	blitscrt_modelist_add(d, &m);

	/* 640x576i50 -- PAL, 15.625 kHz, 50.00 Hz field, 625 lines */
	blitscrt_mode_from_modeline(&m, 12500, 640, 664, 724, 800,
				    576, 582, 588, 625,
				    BLITSCRT_MF_INTERLACE |
				    BLITSCRT_MF_NHSYNC | BLITSCRT_MF_NVSYNC);
	blitscrt_modelist_add(d, &m);

	/* 320x240p60 -- 15.750 kHz, 60.11 Hz, 262 lines */
	blitscrt_mode_from_modeline(&m, 6300, 320, 332, 362, 400,
				    240, 243, 246, 262,
				    BLITSCRT_MF_NHSYNC | BLITSCRT_MF_NVSYNC);
	blitscrt_modelist_add(d, &m);

	/* 320x288p50 -- PAL, 15.625 kHz, 50.08 Hz, 312 lines */
	blitscrt_mode_from_modeline(&m, 6250, 320, 332, 362, 400,
				    288, 291, 294, 312,
				    BLITSCRT_MF_NHSYNC | BLITSCRT_MF_NVSYNC);
	blitscrt_modelist_add(d, &m);
}

/*
 * Heartbeat. Bumped on a timer from the main loop; the fabric watches it and
 * falls back to its own banner if it stops. Also pushes the host-status hint,
 * so the fabric banner can reflect USB state that only the daemon knows.
 */
void blitscrt_dev_heartbeat(struct blitscrt_dev *d)
{
	if (!d->fabric)
		return;
	d->heartbeat++;
	blitscrt_fabric_write(d->fabric, BLITSCRT_REG_HEARTBEAT, d->heartbeat);

	{
		uint32_t hs = d->host_attached
			? (d->controller_enabled ? BLITSCRT_HOST_STREAMING
						 : BLITSCRT_HOST_ATTACHED)
			: BLITSCRT_HOST_NONE;
		blitscrt_fabric_write(d->fabric, BLITSCRT_REG_HOSTSTATE, hs);
	}
}

void blitscrt_dev_refresh_overlay(struct blitscrt_dev *d)
{
	char line[64];

	if (!d->fabric)
		return;

	blitscrt_fabric_overlay_clear(d->fabric);
	blitscrt_fabric_overlay_line(d->fabric, 2, 4, "BLITSCRT_MISTER");
	/* Unmistakable "the daemon is here" line -- the baked idle banner in this
	 * same spot reads "FABRIC  NO HPS YET", so seeing this instead is the proof
	 * that the live overlay, not the baked one, is on screen. */
	blitscrt_fabric_overlay_line(d->fabric, 3, 4, "FABRIC  HPS UP");

	/*
	 * Report the raster, not the request.
	 *
	 * This used to read H_SY..V_FP, PCLK_KHZ and MODE_FLAGS -- all staged
	 * registers, written by software or left at their reset values. They
	 * describe what was asked for, which is not the same thing as what
	 * video_timing is being fed: with the front-panel mode table owning
	 * timing they are simply unrelated, and PCLK_KHZ is a number someone
	 * wrote rather than the clock actually selected. An overlay that reads
	 * plausibly while the screen shows something else is worse than no
	 * overlay, and that exact gap cost a day of hardware debugging.
	 *
	 * LIVE_* is post-mux and derives the pixel clock from clk_sel, so it
	 * cannot disagree with the picture.
	 */
	{
		struct blitscrt_live lv;

		if (blitscrt_fabric_live(d->fabric, &lv) == 0 && lv.h_total) {
			snprintf(line, sizeof line, "MODE   %uX%u%s %.2fHZ",
				 lv.h_act,
				 lv.interlace ? lv.v_act * 2 : lv.v_act,
				 lv.interlace ? "I" : "P", lv.field_hz);
			blitscrt_fabric_overlay_line(d->fabric, 4, 4, line);

			snprintf(line, sizeof line, "LINE   %.3f KHZ",
				 lv.line_hz / 1000.0);
			blitscrt_fabric_overlay_line(d->fabric, 5, 4, line);

			snprintf(line, sizeof line, "PIXEL  %.3f MHZ%s",
				 lv.pclk_hz / 1e6, lv.clk_sel < 2 ? " REF!" : "");
			blitscrt_fabric_overlay_line(d->fabric, 6, 4, line);

			/* Who is driving it. A host mode and a front-panel mode
			 * can read identically, and knowing which is on is the
			 * difference between a working host and a host being
			 * quietly ignored. */
			snprintf(line, sizeof line, "TIMING %s%s",
				 lv.hps_timing ? "HOST" : "PANEL",
				 (lv.hps_timing && !d->active_valid)
				   ? " (STALE)" : "");
			blitscrt_fabric_overlay_line(d->fabric, 7, 4, line);
		}
	}

	snprintf(line, sizeof line, "USB    %s",
		 d->host_attached ? (d->controller_enabled ? "STREAMING"
							   : "ATTACHED")
				  : "NO HOST");
	blitscrt_fabric_overlay_line(d->fabric, 8, 4, line);
	blitscrt_fabric_overlay_line(d->fabric, 9, 4,
				     "OUT    VGA RGB666 + HDMI DV");
}

void blitscrt_dev_on_host(struct blitscrt_dev *d, int attached)
{
	d->host_attached = attached ? 1 : 0;

	if (!attached) {
		/* Nothing is writing scanout memory any more. Show the card
		 * rather than whatever was last left there. */
		d->controller_enabled = 0;
		d->display_enabled    = 0;
		d->active_valid       = 0;
		d->pending_valid      = 0;
		d->buffer_valid       = 0;
		if (d->fabric)
			blitscrt_fabric_enable(d->fabric, 0);
	}

	blitscrt_dev_refresh_overlay(d);
}

static void mode_to_gud(const struct blitscrt_mode *m,
			struct gud_display_mode_req *g)
{
	g->clock       = m->clock_khz;
	g->hdisplay    = m->hdisplay;
	g->hsync_start = m->hsync_start;
	g->hsync_end   = m->hsync_end;
	g->htotal      = m->htotal;
	g->vdisplay    = m->vdisplay;
	g->vsync_start = m->vsync_start;
	g->vsync_end   = m->vsync_end;
	g->vtotal      = m->vtotal;
	g->flags       = m->flags;
}

static void mode_from_gud(const struct gud_display_mode_req *g,
			  struct blitscrt_mode *m)
{
	m->clock_khz   = g->clock;
	m->hdisplay    = g->hdisplay;
	m->hsync_start = g->hsync_start;
	m->hsync_end   = g->hsync_end;
	m->htotal      = g->htotal;
	m->vdisplay    = g->vdisplay;
	m->vsync_start = g->vsync_start;
	m->vsync_end   = g->vsync_end;
	m->vtotal      = g->vtotal;
	m->flags       = g->flags;
}

int blitscrt_handle_ctrl(struct blitscrt_dev *d,
			 uint8_t bRequest, uint16_t wValue, uint16_t wIndex,
			 const void *data, uint16_t data_len,
			 void *buf, size_t buflen)
{
	(void)wValue;
	(void)wIndex;

	switch (bRequest) {

	case GUD_REQ_GET_STATUS: {
		uint8_t s = d->last_status;
		if (buflen < 1) return -1;
		memcpy(buf, &s, 1);
		return 1;
	}

	case GUD_REQ_GET_DESCRIPTOR: {
		struct gud_display_descriptor_req r;
		if (buflen < sizeof r) return -1;
		memset(&r, 0, sizeof r);
		r.magic       = GUD_DISPLAY_MAGIC;
		r.version     = 1;
		/* the Linux gadget cannot control the status stage of a
		 * control OUT with a payload, so it asks for a status request
		 * after every SET */
		r.flags       = GUD_DISPLAY_FLAG_STATUS_ON_SET;
		r.compression = 0;              /* no LZ4, nothing to gain here */
		r.max_buffer_size = 0;
		r.min_width  = 256; r.max_width  = blitscrt_limits_15khz.h_max;
		r.min_height = 192; r.max_height = blitscrt_limits_15khz.v_max;
		memcpy(buf, &r, sizeof r);
		d->last_status = GUD_STATUS_OK;
		return (int)sizeof r;
	}

	case GUD_REQ_GET_FORMATS: {
		/*
		 * The DAC is a six-bit resistor ladder per channel, so RGB666
		 * is what actually reaches the CRT. GUD has no RGB666 format.
		 * RGB888 truncated to 666 uses the whole ladder and is listed
		 * first for that reason; RGB565 gives up a bit on red and blue
		 * but halves the bandwidth. RGB332 is there for the tight
		 * cases. There is no indexed format in GUD at all, so the 4bpp
		 * palette idea does not map.
		 */
		uint8_t f[3] = { GUD_PIXEL_FORMAT_RGB888,
				 GUD_PIXEL_FORMAT_RGB565,
				 GUD_PIXEL_FORMAT_RGB332 };
		if (buflen < sizeof f) return -1;
		memcpy(buf, f, sizeof f);
		d->last_status = GUD_STATUS_OK;
		return (int)sizeof f;
	}

	case GUD_REQ_GET_PROPERTIES:
	case GUD_REQ_GET_CONNECTOR_PROPERTIES:
	case GUD_REQ_GET_CONNECTOR_TV_MODE_VALUES:
		d->last_status = GUD_STATUS_OK;
		return 0;                        /* none */

	case GUD_REQ_GET_CONNECTORS: {
		struct gud_connector_descriptor_req c;
		if (buflen < sizeof c) return -1;
		memset(&c, 0, sizeof c);
		c.connector_type = GUD_CONNECTOR_TYPE_VGA;
		/* INTERLACE must be set here or the host will not offer 480i
		 * at all, whatever the mode list says */
		c.flags = GUD_CONNECTOR_FLAGS_POLL_STATUS |
			  GUD_CONNECTOR_FLAGS_INTERLACE;
		memcpy(buf, &c, sizeof c);
		d->last_status = GUD_STATUS_OK;
		return (int)sizeof c;
	}

	case GUD_REQ_SET_CONNECTOR_FORCE_DETECT:
		d->last_status = GUD_STATUS_OK;
		return 0;

	case GUD_REQ_GET_CONNECTOR_STATUS: {
		uint8_t s = GUD_CONNECTOR_STATUS_CONNECTED;
		if (buflen < 1) return -1;
		/* CHANGED makes the host re-probe and re-read the mode list.
		 * This is how a mode added at runtime becomes visible without
		 * re-enumerating the USB device. */
		if (d->modes_changed) {
			s |= GUD_CONNECTOR_STATUS_CHANGED;
			d->modes_changed = 0;
		}
		memcpy(buf, &s, 1);
		d->last_status = GUD_STATUS_OK;
		return 1;
	}

	case GUD_REQ_GET_CONNECTOR_MODES: {
		size_t need = d->n_modes * sizeof(struct gud_display_mode_req);
		struct gud_display_mode_req *g = buf;
		unsigned int i;
		if (buflen < need) return -1;
		for (i = 0; i < d->n_modes; i++)
			mode_to_gud(&d->modes[i], &g[i]);
		d->last_status = GUD_STATUS_OK;
		return (int)need;
	}

	case GUD_REQ_GET_CONNECTOR_EDID:
		/* no EDID; the mode list is authoritative */
		d->last_status = GUD_STATUS_OK;
		return 0;

	case GUD_REQ_SET_BUFFER: {
		const struct gud_set_buffer_req *r = data;
		if (data_len < sizeof *r) {
			d->last_status = GUD_STATUS_PROTOCOL_ERROR;
			return -1;
		}
		if (!d->active_valid ||
		    r->x + r->width  > d->active_mode.hdisplay ||
		    r->y + r->height > d->active_mode.vdisplay) {
			d->last_status = GUD_STATUS_INVALID_PARAMETER;
			return -1;
		}
		d->buffer = *r;
		d->buffer_valid = 1;
		d->last_status = GUD_STATUS_OK;
		return 0;
	}

	case GUD_REQ_SET_STATE_CHECK: {
		const struct gud_state_req *r = data;
		struct blitscrt_mode m;
		enum blitscrt_mode_result res;

		if (data_len < sizeof *r) {
			d->last_status = GUD_STATUS_PROTOCOL_ERROR;
			return -1;
		}

		mode_from_gud(&r->mode, &m);
		res = blitscrt_mode_check(&m, &blitscrt_limits_15khz,
					  &d->pending_timing);
		if (res != BLITSCRT_MODE_OK) {
			d->pending_valid = 0;
			d->stat_rejected++;
			d->last_status = GUD_STATUS_INVALID_PARAMETER;
			return -1;
		}
		if (r->format != GUD_PIXEL_FORMAT_RGB888 &&
		    r->format != GUD_PIXEL_FORMAT_RGB565 &&
		    r->format != GUD_PIXEL_FORMAT_RGB332) {
			d->pending_valid = 0;
			d->last_status = GUD_STATUS_INVALID_PARAMETER;
			return -1;
		}

		d->pending_mode  = m;
		d->format        = r->format;
		d->pending_valid = 1;
		d->last_status   = GUD_STATUS_OK;
		return 0;
	}

	case GUD_REQ_SET_STATE_COMMIT:
		if (!d->pending_valid) {
			d->last_status = GUD_STATUS_PROTOCOL_ERROR;
			return -1;
		}
		/*
		 * Apply first, and believe the result.
		 *
		 * This used to set active_valid, call set_mode(), discard the
		 * return value and answer GUD_STATUS_OK unconditionally. So a
		 * reconfiguration that timed out, a geometry that did not take,
		 * or a raster that ended up running something else were all
		 * reported to the host as a successful modeset -- and the daemon
		 * then believed it was driving a mode it was not. set_mode()
		 * confirms against the live registers precisely so that its
		 * answer means something; throwing it away wasted that.
		 */
		if (d->fabric &&
		    blitscrt_fabric_set_mode(d->fabric, &d->pending_timing,
					     d->format) < 0) {
			/* Leave active_* alone: whatever was on screen before is
			 * still what is on screen, and saying so is better than
			 * claiming a mode that did not happen. */
			d->pending_valid = 0;
			d->last_status = GUD_STATUS_PROTOCOL_ERROR;
			blitscrt_dev_refresh_overlay(d);
			return -1;
		}
		d->active_mode   = d->pending_mode;
		d->active_timing = d->pending_timing;
		d->active_valid  = 1;
		d->pending_valid = 0;
		d->stat_modeset++;
		blitscrt_dev_refresh_overlay(d);
		d->last_status = GUD_STATUS_OK;
		return 0;

	case GUD_REQ_SET_CONTROLLER_ENABLE:
		if (data_len < 1) { d->last_status = GUD_STATUS_PROTOCOL_ERROR; return -1; }
		d->controller_enabled = *(const uint8_t *)data ? 1 : 0;
		if (d->fabric)
			blitscrt_fabric_enable(d->fabric, d->controller_enabled);
		blitscrt_dev_refresh_overlay(d);
		d->last_status = GUD_STATUS_OK;
		return 0;

	case GUD_REQ_SET_DISPLAY_ENABLE:
		if (data_len < 1) { d->last_status = GUD_STATUS_PROTOCOL_ERROR; return -1; }
		d->display_enabled = *(const uint8_t *)data ? 1 : 0;
		d->last_status = GUD_STATUS_OK;
		return 0;

	default:
		d->last_status = GUD_STATUS_REQUEST_NOT_SUPPORTED;
		return -1;
	}
}
