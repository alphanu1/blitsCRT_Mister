# Interlace at 60 Hz

A 480i picture on a CRT should move at 60 Hz — sixty fields a second, each drawn
from a different render, the way a Mega Drive in two-player mode does. Getting
that from a Linux host takes a trick, because the display stack will not ask an
application to render sixty times a second for an interlaced mode.

## Why, on some machines

RandR rates an interlaced mode at its **frame** rate. From xrandr's own
documentation:

> field rate: Desired field rate in floating point Hz eg. 60.1. In non-interlaced
> modes, this is the same as the frame rate, and in interlaced modes, this is
> double the actual full frame rate.

So a host told "448i at 59.92" renders **30** frames a second. The fabric then
draws sixty fields from thirty renders: correct 480i, full vertical detail, and
half the motion.

Measured on the desktop, `320x448i` asked for 59.92 Hz and the host delivered 33,
with the device idle two thirds of the time. It is not a bandwidth problem and
not a fabric problem -- the raster was right throughout, and the same daemon on
the laptop delivered 60.

Things that do not fix it:

- **Advertising the modes ourselves.** Modes in DRM's own list do get the
  doubled rate, which is why the built-in `648x480i60` runs at 60. But Switchres
  computes a modeline per title from the actual refresh, so a fixed list cannot
  anticipate them without running to hundreds of entries, and a host picking from
  a list still would not get the exact clock.
- **The 15 kHz kernel patches**, mostly. See below -- one is the right idea and
  has nothing here to correct; three may matter after all.
- **`interlace 0` in switchres.ini.** Gets 60 Hz motion by not being interlaced:
  224 progressive lines instead of 448.

## The 15 kHz kernel patches

`D0023R/linux_kernel_15khz` carries the patch set GroovyArcade and Batocera use.
Most of it makes a real graphics card emit 15 kHz, which this project does not
need -- the board generates its own raster and the host only sends pixels.

| patch | what it does | here |
|---|---|---|
| `01_linux_15khz` | a hard-coded 15 kHz mode table selected by `video=VGA-1:640x480ieS` | not needed; modes arrive over GUD |
| `02_..._interlaced_mode_fix` | stops DRM trusting the hardware vblank counter for interlaced modes | **right idea, nothing to correct** |
| `03/04_..._dcn/dce_interlaced_mode_fix` | enable interlaced mode on amdgpu | **possibly relevant -- see below** |
| `05_..._amdgpu_pll_fix` | amdgpu PLL calculation | possibly, same reason |
| `06_..._switchres_kms_drm_modesetting` | Switchres through KMS, bypassing xrandr | untested, and it targets the right layer |
| `07_..._fix_ddc` | oops when probing DDC with no adapter | unrelated |
| `08_..._interlace_force_even` | force even fields on amd DCN1 | unrelated |

**Patch 02 is worth understanding even though it does not apply.** It is the
same diagnosis reached here from the other end:

```c
/* We can't use the hw counter for interlace modes */
if (max_vblank_count && !(crtc->hwmode.flags & DRM_MODE_FLAG_INTERLACE)) {
        /* trust the hw counter when it's around */
```

Hardware vblank counters tick once per **frame** in interlace, so a vsynced
application gets 30 ticks a second where it needs 60. The fix falls back to
timestamps and `framedur_ns`, which is derived from the halved `crtc_vtotal` and
therefore counts fields. That is exactly what correct looks like.

It cannot help here because it works by distrusting a hardware counter, and
`gud` has none -- confirmed on the board:

```
$ sudo ls /sys/kernel/debug/dri/3-4:1.0/
clients  crtc-0  encoder-0  framebuffer  name  state  VGA-1
```

No vblank entry. There is no interrupt to fix.

**Patches 03-05 were dismissed too early.** The reasoning was that this project
does not use a GPU for output, which is true of the video path and false of the
render path -- see the GPU section below.

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

## Two profiles, one daemon

Whether the display stack halves an interlaced mode is not universal. Measured on
the same daemon, the same distribution and the same X11, with vsync on:

| | kernel | desktop | GPU | 320x448i |
|---|---|---|---|---|
| desktop PC | 7.1.5-zen1-2-zen | Plasma, compositing on **or off** | Radeon RX 9070 XT | **30 fields/s** |
| laptop | 7.1.6-arch-1-1 | XFCE | Intel Iris | **60 fields/s** |

**The compositor has been ruled out.** KWin looked like the obvious suspect --
it composites by default and paces fullscreen windows through its own redraw
loop -- but the PC gives 30 with compositing on *and* off. So it is not that.

Two things remain, and the **GPU is the more interesting**.

### The GPU, and why it can matter at all

The display is a USB device, so no GPU is in the video path. But one is in the
*render* path: with a discrete card driving X, the `gud` output is a secondary
sink and frames reach it by reverse-PRIME offload -- rendered on the AMD GPU,
copied to the USB display. A laptop whose iGPU is the only device may not offload
at all.

That reopens something dismissed earlier. Patches 03, 04 and 05 of the 15 kHz
kernel set are **amdgpu interlace fixes** -- "enable interlaced mode on standalone
graphic cards and APU". They were written off here on the grounds that this
project does not use a GPU for output, which is true of the video path and not
of the offload path. If amdgpu is doing the mode arithmetic or pacing the copy,
they may bear on this after all.

Untested. The cheap version is to force rendering on the CPU and see whether the
rate changes:

```
LIBGL_ALWAYS_SOFTWARE=1 retroarch
```

Slow, but if 448i comes back at 60 fields a second, the offload path is
implicated and the amdgpu patches are worth trying.

### The kernel

One point release apart, and one carrying the zen patchset. Booting stock 7.1.6
on the PC would separate them. Weaker than the GPU as an explanation, but not
excluded.

Either way the daemon copes, and the profile decides which route is taken.

So the daemon supports both and chooses per mode, with no configuration of its
own. The rewrite fires only when **all** of these hold:

- the line rate is above the 15 kHz band,
- half of it is inside the band,
- and the mode is **not already interlaced**.

An interlaced mode is therefore always passed through exactly as it arrives.
Which mechanism is used is decided entirely by the monitor profile.

### If interlace already works

Change nothing. A stock 15 kHz profile generates interlaced modes, the daemon
passes them through, and the host renders at the field rate.

```ini
	monitor                   arcade_15
	interlace                 1
```

### If interlace runs at half speed

Switch to the dual-range profile below and turn Switchres's own interlace off, so
448-line content has only one home -- the 31 kHz range, progressive, which the
daemon halves.

```ini
	monitor                   custom
	interlace                 0
```

`interlace 0` matters more than it looks. With it left at 1, `crt_range0` can
satisfy 448 lines directly as a 15 kHz interlaced mode -- the more obvious match
-- so Switchres never reaches the 31 kHz range and nothing is converted. Setting
the interlaced line counts to `0, 0` on both ranges makes that explicit.

## The monitor profile

Two ranges. The 15 kHz one for short modes, which pass through untouched; the
31 kHz one for tall modes, which get halved. Only modes outside the band whose
half is inside it are converted, so 224p content is never touched.

The 31 kHz range must be **exactly double** the 15 kHz one, so that everything it
generates lands in the band after halving:

```ini
	monitor                   custom
	interlace                 0

# 15 kHz: 224p/240p content, passed through unchanged. Interlaced line counts
# are 0,0 so this range cannot offer interlace even if the flag were on --
# otherwise it satisfies 448 lines directly and crt_range1 is never reached.
	crt_range0                15625-16500, 49.50-65.00, 2.000, 4.700, 8.000, 0.064, 0.192, 1.024, 0, 0, 192, 288, 0, 0

# 31 kHz: 448p/480p/576p content, halved into 15 kHz interlaced by the daemon.
# Exactly double crt_range0's horizontal times, so doubling on conversion lands
# on the sync width a 15 kHz set wants.
	crt_range1                31250-33000, 49.50-65.00, 1.000, 2.350, 4.000, 0.032, 0.096, 0.512, 0, 0, 384, 576, 0, 0
```

Vertical totals do **not** need to come out odd. An even one is handled by
solving the clock, as above.

**The horizontal times must be halved, and this is the one thing that will bite.**

The daemon does not touch horizontal porches. Pixel counts pass through unchanged,
so halving the clock doubles every horizontal duration — which is exactly right
when the 31 kHz modeline was generated with half-width porches:

| | sync px | at 31 kHz | at 15 kHz |
|---|---|---|---|
| `crt_range1` above | 32 | 2.45 µs | **4.91 µs** |
| stock VGA 640x480p60 | 96 | 3.81 µs | **7.63 µs** |

A 15 kHz set wants about 4.7 µs. The halved range lands on it; a stock VGA
modeline is nearly double, which shifts the picture and may lose lock on a fussy
set. `mode_check` warns when the converted sync falls outside 3.0–6.5 µs rather
than refusing, since the fix is in the profile and refusing would just mean no
picture:

```
blitscrt: 7.63 us of hsync after conversion, wanted about 4.7 --
is crt_range1 carrying half the porch times of crt_range0?
```

Rescaling the porches in the daemon was considered and rejected. Switchres
computes them from the monitor profile deliberately, and overriding that would
fight the tool that knows the monitor.

Vertical needs no such care. Line counts halve per field, so durations are
preserved: 6 lines of sync at 31 kHz is 191.5 µs, and 3 lines per field at 15 kHz
is also 191.5 µs. An odd count loses half a line to integer division — a 63-line
back porch becomes 31, costing 32 µs — which `mode_check` absorbs into the back
porch so the totals still close.

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
