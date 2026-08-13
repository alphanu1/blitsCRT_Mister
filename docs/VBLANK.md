# Vblank

**Not implemented. This is M8.**

`gud` reports no vblank at all. Confirmed on hardware:

```
$ sudo ls /sys/kernel/debug/dri/3-3:1.0/
clients  crtc-0  encoder-0  framebuffer  name  state  VGA-1
```

No vblank entry, and `/sys/kernel/debug/dri/*/vblank_stats` does not exist. So
an application asking to synchronise to this display gets nothing to
synchronise to.

## Why it matters here more than for other USB displays

`gud` was written for small SPI panels where the host draws when it likes and
the panel holds the last thing it was given. Nothing is scanning out; there is
no beam and no frame boundary, so there is nothing for a vblank to mean.

This board is the opposite. It generates a real raster at a real rate, and the
whole point of the project is that the rate is exact -- 0 ppm across both bands
with the fractional PLL, because a 15 kHz 2D game scrolling a whole screen shows
any mismatch as a repeated or dropped frame. Having gone to that trouble in the
fabric, the host is then free to render whenever it likes.

Measured, with vsync on and the laptop's own panel disabled so nothing else
could be driving it:

| mode | asked | delivered |
|---|---|---|
| 320x240p | 59.99 Hz | 186 frames/s |
| 352x224p | 59.82 Hz | 128 frames/s |
| 330x224p | 59.83 Hz | 95 frames/s |

The host is not being paced by anything. Frames land in DDR3 whenever they are
ready, and the fabric shows whatever is there as the beam passes -- so a frame
written mid-scan tears, and most of what the host produced is discarded.

## What is needed

DRM has a standard answer for a display with no vblank interrupt: drive it from
an hrtimer. vkms did it first, and virtgpu, vmwgfx and amdgpu's virtual display
all copy the same shape. The pieces:

| | |
|---|---|
| `enable_vblank` | start an hrtimer with a period of `vblank->framedur_ns`, which DRM has already computed from the mode |
| the timer callback | `hrtimer_forward_now()` **first**, then `drm_crtc_handle_vblank()` -- in that order, see below |
| `disable_vblank` | `hrtimer_cancel()` |
| `get_vblank_timestamp` | `drm_crtc_vblank_helper_get_vblank_timestamp` if `get_scanout_position` is implemented, otherwise the vkms-style version |
| `get_vblank_counter` | `drm_vblank_no_hw_counter`, since there is no hardware counter to read |
| at init | `drm_vblank_init()`, and `drm_calc_timestamping_constants()` on each modeset |

The ordering matters and has bitten people before. From the vkms fix:

> The reason for this is that once we've called drm_crtc_handle_vblank and the
> hrtimer isn't forwarded yet, we're returning a vblank timestamp in the past.

There is also work in flight to move this into the core as
`DRM_CRTC_VBLANK_TIMER`, so drivers only start and cancel it. Worth checking
whether that has landed before writing anything.

## Why we can do better than a timer

Every other driver using this pattern is guessing: there is no real raster, so
an hrtimer at the nominal rate is as good as it gets, and the comment on the
core patch says as much -- *"the timer is not synchronized to the actual vblank
interval of the display."*

**We have an actual vblank.** The fabric knows exactly when the beam reaches the
end of a field, because it generates the timing. A free-running timer on the
host would drift against it, and drift is what this project exists to avoid.

Two ways to close that, and the second is better:

**Timer, corrected.** Run the hrtimer as everyone else does, but discipline it
against a frame counter read back from the fabric so it cannot walk. Simple, no
protocol change, and the correction interval has to be long enough not to jitter
the timer itself.

**A real vblank over the wire.** The fabric raises a flag at each field end and
the device sends it to the host, which calls `drm_crtc_handle_vblank()` on
arrival. That is a genuine hardware vblank, late by the USB latency -- a few
hundred microseconds, constant enough to subtract.

The second needs a GUD protocol addition, which is the significant part: GUD is
a wire protocol with other implementations, so an event channel is not something
to add casually. An interrupt endpoint is the obvious shape; the device already
has spare endpoints.

## What it would fix

**Tearing.** The host would render one frame per field instead of two or three,
and each would land in the blanking interval rather than mid-scan.

**Wasted work.** At 186 fps against a 60 Hz raster, two thirds of what the host
renders is overwritten before it is displayed. That is CPU, GPU, USB bandwidth
and LZ4 compression spent on frames nobody sees.

**Frame pacing.** An emulator with vsync on would actually be synchronised to
the display, which is the point of running a CRT at an exact rate.

It would also make the interlace situation better without solving it: the host
would at least be paced, even if RandR still reports the wrong refresh (see
`docs/INTERLACE.md`).

## Where the work sits

`gud` is in-tree, so this is a kernel patch plus a device-side change, and
upstreaming means convincing the `gud` maintainer that a display which really
scans out is worth supporting. The timer-only version is a small patch that
helps every `gud` user; the protocol event is specific to devices like this one
and is the harder conversation.

Starting with the timer is the sensible order: it is useful on its own,
independent of the protocol question, and it establishes whether the pacing
alone fixes the tearing before anything is added to the wire.
