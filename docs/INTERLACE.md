# Interlace at 60 Hz

A 480i picture on a CRT should move at 60 Hz — sixty fields a second, each drawn
from a different render, the way a Mega Drive in two-player mode does. Getting
that from a Linux host takes a trick, because the display stack will not ask an
application to render sixty times a second for an interlaced mode.

## Why not

RandR rates an interlaced mode at its **frame** rate. From xrandr's own
documentation:

> field rate: Desired field rate in floating point Hz eg. 60.1. In non-interlaced
> modes, this is the same as the frame rate, and in interlaced modes, this is
> double the actual full frame rate.

So a host told "448i at 59.92" renders **30** frames a second. The fabric then
draws sixty fields from thirty renders: correct 480i, full vertical detail, and
half the motion.

Measured on hardware, `320x448i` asked for 59.92 Hz and the host delivered 33,
with the device idle two thirds of the time. It is not a bandwidth problem and
not a fabric problem — the raster was right throughout.

Things that do not fix it:

- **Advertising the modes ourselves.** Modes in DRM's own list do get the
  doubled rate, which is why the built-in `648x480i60` runs at 60. But Switchres
  computes a modeline per title from the actual refresh, so a fixed list cannot
  anticipate them without running to hundreds of entries, and a host picking from
  a list still would not get the exact clock.
- **The 15 kHz kernel patches.** `02_linux_15khz_interlaced_mode_fix.patch` is
  the right idea — it stops DRM trusting a hardware vblank counter for interlaced
  modes, because those count frames rather than fields. But it works by falling
  back to timestamps when a hardware counter exists, and `gud` has no vblank at
  all. Nothing for it to correct.
- **`interlace 0` in switchres.ini.** Gets 60 Hz motion by not being interlaced:
  224 progressive lines instead of 448.

## What does

**Never tell the host it is interlaced.** Ask it for a 31 kHz *progressive* mode
of the full frame height, and halve that into 15 kHz interlaced on arrival.

```
Switchres generates   13.036 MHz / 416 / 523     31.337 kHz, 59.92 Hz progressive
daemon halves         6.518 MHz / 416 / 261 i    15.668 kHz, 59.92 Hz field
```

The host sees no interlace flag, so nothing halves its rate: it allocates a
448-line surface and renders sixty frames a second into it. The fabric emits a
15 kHz interlaced raster reading alternate rows, so **each field comes from a
different render** — 448 distinct lines at 60 Hz motion.

The conversion is refresh-preserving by construction. Halving the clock and the
vertical total divides both sides of `clock/(htotal*vtotal)`, so the field rate
equals the progressive rate the host was given — whatever Switchres computed, and
however the PLL later rounds it. Clock accuracy is unaffected: the fabric still
solves the real 6.518 MHz, at −9 ppm today and better with a fractional PLL.

No fabric changes. `video_timing.v` already interleaves:

```verilog
assign ypos = interlace ? {yr[10:0], fr} : yr;
```

## The half line, and why the clock is solved rather than halved

An interlaced frame is `2 * field + 1` lines. The half line is what offsets one
field against the other; without it both fields land on the same scanlines and
the picture is 224 lines drawn twice, not 448. It cannot be dropped to make the
arithmetic tidy.

Which means an even host total does not simply halve. 522 progressive lines
become 261 field lines plus the half line — 261.5 — and a clock of exactly half
runs the field rate **1912 ppm slow**. That is 0.11 frames a second: a dropped
field every **nine seconds**, plainly visible on anything scrolling.

But the fabric's clock is ours to choose, and what has to match is the field
*rate*, not the ratio to the host's clock:

```
fabric_clock = host_clock * (field_total + 0.5) / host_vtotal
```

Exactly half when the total is odd, a little over half when it is even, and 0 ppm
either way:

| host vtotal | naive half | solved | error |
|---|---|---|---|
| 523 (odd) | 6.518000 MHz | 6.518000 MHz | 0 ppm |
| 522 (even) | 6.518000 MHz | **6.530487 MHz** | 0 ppm |

The deviation from "half" is invisible — 0.19% on a pixel clock changes nothing a
CRT can see, while 0.19% on the frame rate is a dropped field every nine seconds.

The clock is carried in Hz rather than the mode's integer kHz for the same
reason: rounding 6530.487 kHz to 6530 costs 75 ppm, and there is no need to spend
it when the PLL solver takes Hz.

## The monitor profile

Two ranges. The 15 kHz one for short modes, which pass through untouched; the
31 kHz one for tall modes, which get halved. Only modes outside the band whose
half is inside it are converted, so 224p content is never touched.

The 31 kHz range must be **exactly double** the 15 kHz one, so that everything it
generates lands in the band after halving:

```ini
# 15 kHz: 224p/240p content, passed through unchanged
crt_range0  15625-16500, 49.50-65.00, 2.000, 4.700, 8.000, 0.064, 0.192, 1.024, 0, 0, 192, 288, 448, 576

# 31 kHz: 448p/480p/576p content, halved into 15 kHz interlaced by the daemon.
# Exactly double crt_range0's horizontal band so the halved result lands inside
# it. The vertical totals it generates must come out odd -- see above.
crt_range1  31250-33000, 49.50-65.00, 1.000, 2.350, 4.000, 0.032, 0.096, 0.512, 0, 0, 384, 576, 896, 1152
```

Vertical totals do **not** need to come out odd. An even one is handled by
solving the clock, as above.

Horizontal porches halve with the line rate; vertical porches halve in time but
double in lines, so they stay the same line count per frame.

Worked examples:

| content | host | fabric | vtotal |
|---|---|---|---|
| Mega Drive 2P 448p | 31.337 kHz | 15.668 kHz | 523 |
| NTSC 480p → 480i | 31.469 kHz | 15.734 kHz | 525 |
| PAL 576p → 576i | 31.250 kHz | 15.625 kHz | 625 |

and in `switchres.ini`:

```ini
	interlace                 1
	modeline_generation       1
```

Leave `interlace 1`. Switchres may still generate a genuinely interlaced mode for
content it judges needs one, and those still work — they just run at 30 Hz motion
as before. The conversion only applies to progressive modes.

## Checking it worked

`make -C sw daemon` and watch the log on a modeset:

```
blitscrt: mode 320x224i applied
  ...
  host renders at 59.92 Hz (interlaced: DRM doubles the frame rate)
  rewritten from a 31 kHz progressive mode: the host renders whole
  frames at the field rate, so each field is a different render
```

That last line is the one to look for. Then the rate line should read close to
**60 fields/s** rather than 30, with `rects/s` near 60.
