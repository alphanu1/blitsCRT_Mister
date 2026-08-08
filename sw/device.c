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
#include "edid.h"
#include "fabric.h"
#include "blitscrt_regs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void dev_tick(void *arg)
{
	blitscrt_dev_heartbeat((struct blitscrt_dev *)arg);
}

void blitscrt_dev_init(struct blitscrt_dev *d, struct blitscrt_fabric *f)
{
	memset(d, 0, sizeof *d);
	d->fabric      = f;
	d->last_status = GUD_STATUS_OK;
	d->format      = GUD_PIXEL_FORMAT_RGB565;
	/* Keep the watchdog fed through anything in the fabric layer that waits
	 * -- a PLL reconfiguration takes over a second, and losing hps_alive
	 * mid-modeset drops the raster back to the test card. */
	blitscrt_fabric_set_tick(f, dev_tick, d);

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

	/*
	 * Nor anything wider than the scanout line buffer.
	 *
	 * A mode past that scans out wrapped lines -- two pictures side by side,
	 * with nothing to suggest a buffer is the cause. The fabric reports its
	 * own width so this cannot be got wrong by editing a parameter in one
	 * place and having it overridden in another, which is exactly how a
	 * 1024-pixel buffer survived being "raised" to 1280.
	 *
	 * A fabric too old to report it returns 0, and is left alone rather than
	 * having every mode refused.
	 */
	if (d->fabric) {
		unsigned maxw = blitscrt_fabric_max_width(d->fabric);

		if (maxw && m->hdisplay > maxw) {
			fprintf(stderr, "blitscrtd: %ux%u not advertised -- the "
					"scanout line buffer holds %u pixels\n",
				m->hdisplay, m->vdisplay, maxw);
			return -1;
		}
	}

	d->modes[d->n_modes++] = *m;
	d->modes_changed = 1;
	return 0;
}

void blitscrt_modelist_defaults(struct blitscrt_dev *d)
{
	struct blitscrt_mode m;

	/*
	 * One mode: 648x480i60.
	 *
	 * Not 640, on purpose. Switchres generates 640-wide timings, and a host
	 * offered both would have two modes that look interchangeable and are
	 * not -- ours is a fixed fallback, its are computed for the monitor in
	 * front of it. A few pixels of difference is invisible on a CRT and makes
	 * the two impossible to confuse in a mode list or a log.
	 *
	 * 648 rather than 642, which was tried first and sheared: 1284 bytes is
	 * 160.5 f2sdram beats, so every line began at a different byte within a
	 * beat. 648 gives 1296, which is 162 exactly.
	 *
	 * That is no longer a constraint. blitscrt_scanout_configure() pads the
	 * stride to a whole beat, so any width works -- which it has to, since a
	 * Switchres modeline never passes through this list. 642 was advertised
	 * alongside 648 for a while to prove that on hardware and both were
	 * stable, so the padding is tested rather than merely reasoned about.
	 *
	 * 648 is kept because it needs no padding, and there is no reason to
	 * prefer a width that does.
	 *
	 * The raster is otherwise the standard 15 kHz 480i one: 800 total at
	 * 12.600 MHz gives 15.750 kHz and a 60.00 Hz field rate, with the extra
	 * active pixels taken out of the porches rather than the line.
	 *
	 * BLITSCRT_MODES=preferred is a no-op now there is only one mode. Kept
	 * because it costs nothing and a second fallback may yet be wanted.
	 */
	blitscrt_mode_from_modeline(&m, 12600, 648, 670, 730, 800,
				    480, 486, 492, 525,
				    BLITSCRT_MF_INTERLACE |
				    BLITSCRT_MF_PREFERRED |
				    BLITSCRT_MF_NHSYNC | BLITSCRT_MF_NVSYNC);
	blitscrt_modelist_add(d, &m);

	/*
	 * Second mode: 632x240p60. Opt-in, for timing a mode switch.
	 *
	 * A single advertised mode leaves no way to make a host issue a
	 * SET_MODE, so there is nothing to measure the modeset path with.
	 * This gives a host something to switch to.
	 *
	 * 632 for the same reason 648 is 648: a width no Switchres modeline
	 * will produce, so a log line names which mode is live without
	 * ambiguity. 632 at 16bpp is 1264 bytes, 158 f2sdram beats exactly,
	 * so it needs no stride padding either -- the switch being timed is
	 * then a mode switch and not a padding path.
	 *
	 * Same 12.600 MHz and same 800-total line, so the PLL counters do not
	 * change between the two. blitscrt_fabric_pll_reconfig() is called
	 * regardless, so the reconfig wait is still exercised; what is not
	 * exercised is a VCO change. A 632-wide active cannot fit an 800/2
	 * line, so there is no half-clock partner for it -- timing a
	 * clock-changing switch needs a narrower mode than this one.
	 *
	 * What does change is v_total and the interlace flag: 525 interlaced
	 * against 262 progressive. That is the whole set_mode path, timing
	 * registers, scanout geometry and the LIVE_* confirm included.
	 *
	 * Advertised unconditionally, like every other mode here. Set
	 * BLITSCRT_MODES=noswitchtest to suppress it once it has served its
	 * purpose, or delete this block.
	 */
	{
		const char *ml = getenv("BLITSCRT_MODES");

		if (!(ml && strstr(ml, "noswitchtest"))) {
			blitscrt_mode_from_modeline(&m, 12600,
						    632, 656, 716, 800,
						    240, 243, 246, 262,
						    BLITSCRT_MF_NHSYNC |
						    BLITSCRT_MF_NVSYNC);
			if (blitscrt_modelist_add(d, &m) == 0)
				fprintf(stderr, "blitscrtd: switch-test mode "
						"632x240p60 advertised\n");
			else
				fprintf(stderr, "blitscrtd: switch-test mode "
						"632x240p60 REFUSED\n");
		}
	}
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
		if (d->gadget_bound)
			hs |= BLITSCRT_HOST_BOUND;
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

	/*
	 * The overlay is for when there is nothing else to look at.
	 *
	 * It reports mode, line rate, pixel clock and whether the HPS is alive,
	 * which is exactly what is wanted on an idle screen and exactly what is
	 * not wanted painted over a desktop. So it goes when a host attaches and
	 * comes back when one leaves.
	 *
	 * The front-panel button inverts this in the fabric rather than being
	 * ANDed with it, so a press shows the overlay while a host is driving and
	 * hides it when one is not. That is worth having: the overlay reads the
	 * timing back from LIVE_*, so it says what the raster is really running
	 * rather than what the host asked for, and that is most worth seeing
	 * exactly when a host is connected.
	 */
	if (d->fabric)
		blitscrt_fabric_overlay_show(d->fabric, !d->host_attached);

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
		/*
		 * LZ4 offered. 640x480i60 full-frame is 36.9 MB/s raw against
		 * about 35 of bulk, so 1.2x clears 60 fps -- and 1.2x is the
		 * figure for photographic video, all noise and gradient. Sprite
		 * output is flat fields and repeated tiles from a small palette
		 * and does far better. The host decides per rect and says so in
		 * gud_set_buffer_req, so an incompressible one costs nothing.
		 */
		/*
		 * LZ4 on by default. BLITSCRT_LZ4=0 turns it off.
		 *
		 * It was opt-in for a while, when the header and data would stop
		 * lining up under load and never recover. That turned out to be
		 * the bulk read size rather than compression -- see the reader in
		 * gadget.c -- and with it fixed this has run without a bad block.
		 *
		 * The default belongs here rather than in init: the daemon should
		 * behave the same however it is started, and tying it to an
		 * environment variable set by the boot path means running it by
		 * hand quietly gets something else.
		 *
		 * Worth having on: 2.58x on real traffic takes a full-screen
		 * 640x480i60 from 51.98 fps to 60.
		 */
		{
			const char *e = getenv("BLITSCRT_LZ4");
			int off = e && (e[0] == '0' || e[0] == 'n' || e[0] == 'N');
			r.compression = off ? 0 : GUD_COMPRESSION_LZ4;
		}
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
		 * RGB888 truncated to 666 would use the whole ladder, which is
		 * why it was listed first. There is no indexed format in GUD at
		 * all, so the 4bpp palette idea does not map.
		 *
		 * RGB888 is not offered, because scanout_fetch.v cannot read it:
		 * three bytes per pixel straddles the 64-bit beat boundary, and
		 * the lane extractor handles 1, 2 and 4-byte formats only. It
		 * treats RGB888 as 4 bytes to keep the address arithmetic sane,
		 * so a host packing at 3 gets a picture whose stride drifts
		 * further out of phase across every line -- vertical striping
		 * and colour fringing, worse toward the right. Seen on hardware
		 * the first time a desktop reached the CRT.
		 *
		 * Advertising it first meant the host took it by default, so
		 * the first working picture was also a broken one. It goes back
		 * when the fetcher gets a two-beat read window -- the one M5
		 * item still outstanding, and worth doing since RGB888 is both
		 * the only format that wastes no ladder depth and the only deep
		 * one that fits a 640-wide mode with LZ4.
		 */
		uint8_t f[2] = { GUD_PIXEL_FORMAT_RGB565,
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

	case GUD_REQ_GET_CONNECTOR_EDID: {
		/*
		 * Off unless BLITSCRT_EDID=1.
		 *
		 * The block carries a name so a host stops calling this
		 * "VGA-1-unknown", and a sync range so it knows what the
		 * deflection circuit will take. It deliberately carries no
		 * timings, on the reasoning that a host cannot prefer a mode it
		 * has not been given.
		 *
		 * That reasoning was wrong. Tested on hardware, a host offered
		 * this EDID picks a mode wider than the raster and loses frames:
		 * the range limits alone are enough to change how it chooses,
		 * without a single timing in the block. Whatever it does with
		 * them, it is not simply reading the mode list.
		 *
		 * So the name is not worth it by default. The mode list stays the
		 * only thing a host is told, which is the arrangement that works.
		 */
		/*
		 *   unset  no EDID at all. The connector reads
		 *          "VGA-1-unknown" and the picture is right.
		 *   name   the name descriptor only -- nothing a host can
		 *          compute a mode from.
		 *   full   name and range limits. Known to make a host pick a
		 *          mode wider than the raster; kept for investigating
		 *          why.
		 */
		const char *mode = getenv("BLITSCRT_EDID");
		int want_name  = mode && (mode[0] == 'n' || mode[0] == 'f' ||
					  mode[0] == '1');
		int want_range = mode && mode[0] == 'f';
		size_t n;

		if (!want_name) {
			d->last_status = GUD_STATUS_OK;
			return 0;
		}

		{
			const struct blitscrt_sink_limits *L =
				&blitscrt_limits_15khz;
			n = blitscrt_edid_build(buf, buflen, "blitsCRT",
						want_range,
						L->line_hz_min / 1000,
						(L->line_hz_max + 999) / 1000,
						L->field_hz_min,
						L->field_hz_max,
						L->pclk_khz_max);
		}
		d->last_status = GUD_STATUS_OK;
		return (int)n;
	}

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

		/*
		 * The mode exactly as the host sent it, before anything here
		 * touches it.
		 *
		 * Everything downstream logs the mode after mode_check has
		 * split an interlaced one into fields, by which point a mode we
		 * advertised and a mode Switchres invented look identical. The
		 * difference that matters -- whether the host is describing
		 * frames or fields, and what refresh it therefore thinks the
		 * mode has -- is only visible here.
		 *
		 * `drm refresh` is what DRM's drm_mode_vrefresh() computes:
		 * clock/(htotal*vtotal), doubled for interlace. If the host is
		 * rendering at half that, it is reading the rate from somewhere
		 * else -- RandR rates an interlaced mode at its frame rate and
		 * does not double.
		 */
		{
			const struct gud_display_mode_req *q = &r->mode;
			unsigned ht = q->htotal, vt = q->vtotal;
			int il = (q->flags &
				  GUD_DISPLAY_MODE_FLAG_INTERLACE) ? 1 : 0;
			double vr = (ht && vt)
				  ? (double)q->clock * 1000.0 / (ht * vt)
				    * (il ? 2 : 1)
				  : 0.0;

			fprintf(stderr,
				"blitscrtd: host asks for %ux%u%s  clk %u kHz\n"
				"  H %u %u %u %u   V %u %u %u %u   flags 0x%x\n"
				"  drm refresh %.2f Hz%s\n",
				q->hdisplay, q->vdisplay, il ? "i" : "p",
				q->clock,
				q->hdisplay, q->hsync_start, q->hsync_end, ht,
				q->vdisplay, q->vsync_start, q->vsync_end, vt,
				q->flags,
				vr, il ? " (doubled for interlace)" : "");
			fflush(stderr);
		}

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
