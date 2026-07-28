# How it works

The parts of the design worth understanding before changing anything. The README
covers what it is and how to run it; this covers how it does it.

## Modes and how one is picked

Every mode goes out **both connectors at once**. `VGA_R/G/B` and `HDMI_TX_D`
come off the same pixel stream. There is no such thing as a per-output mode.
The only difference between the two paths is that the analog pins are released
rather than driven when the A/V board is not fitted.

**640x480i60 is the default.** It is a standard SD format. An HDMI sink takes it
where it would refuse 640x240p, and a 15kHz CRT is happy with it either way. I picked it as the mode most likely to give a picture on whatever is
plugged in.

At reset the mode follows what is fitted: the analog board picks `DEFAULT_VGA`,
otherwise `DEFAULT_HDMI`. Both are 1. `BTN_OSD` cycles from there, since no
amount of detection can tell whether the cable past the connector is any good.
`LED_HDD` blinks the mode number. The running mode stays readable with no
picture and no serial console.

```
set_parameter -name DEFAULT_VGA  1    # analog board fitted
set_parameter -name DEFAULT_HDMI 1    # HDMI only
set_parameter -name FORCE_MODE   -1   # 0/1/2 pins one, ignoring detection
```

Drop `DEFAULT_VGA` to 0 for 240p once the analog path is known good. Setting
either to 2 comes up at 31kHz VGA timing, which needs no DAC at all.

**Mode 2 is there for diagnosis.** Standard VGA timing needs no DAC and no
SCART lead. If mode 0 is dark and mode 2 shows a picture, the fault is in the
cable, not the design.

### Why two clocks and not three

I wanted three. `altclkctrl` on Cyclone V only takes PLL outputs on two of its
four inputs; the other two want real clock pins, and Quartus is blunt about
it:

```
Error (15836): inclk[0] port of Clock Select Block is driven by ... altera_pll ...
but must be driven by a clock pin; PLL output clocks should be moved to inclk[2] or inclk[3]
```

So I arranged the three modes to need two clocks. 12.600 MHz carries both 15kHz
modes at the same 15.750 kHz line rate, and 25.200 MHz carries the 31kHz one.
Both counters hang off one VCO at 1260 MHz, C=100 and C=50 — a single PLL with
two outputs. Slots 0 and 1 of the mux go to the 50 MHz reference, which is a
clock pin and keeps Quartus happy.

The video pipeline is held in reset across a clock switch. Arbitrary Switchres
clocks come from `altera_pll_reconfig` retuning the PLL, which a modeset does
before latching the new timing.

## The write path

The host does not send frames. GUD is a damage-rect protocol: after
`GUD_REQ_SET_BUFFER` names a rectangle, a bulk transfer carries only the pixels
inside it. A cursor moving across a static screen costs a few hundred bytes,
not a megabyte.

Rects land in scanout memory and the raster reads from it. There is no present
and no flip; the write path goes straight at the picture. GUD's kernel header
happens to call that region a framebuffer, but nothing in the protocol submits
a frame.

### Pixel formats

The A/V board is a six-bit resistor ladder per channel. **RGB666** is what
actually reaches the CRT. HDMI carries the same pixels widened to RGB888 by
replicating the top bits.

GUD has no RGB666 format and no indexed format either. The 4bpp palette idea
from BlitCRT does not map onto it at all. Three formats are offered:

| format | bytes/px | reaches the DAC as | note |
|---|---|---|---|
| **RGB888** | 3 | full 6/6/6 | truncated to the ladder, nothing wasted |
| RGB565 | 2 | 5/6/5 into 6/6/6 | gives up a bit on red and blue, halves the bandwidth |
| RGB332 | 1 | 3/3/2 into 6/6/6 | for tight bandwidth |

RGB888 would use the whole ladder and is not currently offered: `scanout_fetch.v`
cannot read three bytes per pixel. RGB565 is what a host gets, and what the
picture on the CRT is made of. See **M5** for the two-beat read window that
brings it back.

### Scanout memory

Two tiers are used, which is a different situation from the Cyclone IV BlitCRT
was built on.

| | size | notes |
|---|---|---|
| **M10K on-chip** | ~696 KB | no controller, lowest latency, no arbitration |
| **HPS DDR3** | 1 GB | always fitted, reached over the f2sdram bridge |

The MiSTer SDRAM module is deliberately not among them. Pixels arrive in DDR3
because that is where the USB gadget receives them, so putting them in a
fabric-side memory would mean reading them back out and pushing every one across
a bridge into something smaller, slower and optional. There is no SDRAM
controller in the design and none is planned.

What fits on-chip, leaving headroom for the rest of the design:

| mode | RGB332 | RGB565 | RGB888 |
|---|---|---|---|
| 640x240p60 | 150 KB, double-buffered | 300 KB, single | 450 KB, single |
| 640x480i60 | 300 KB, single | 600 KB, off-chip | 900 KB, off-chip |
| 640x480p60 | 300 KB, single | 600 KB, off-chip | 900 KB, off-chip |

That table is about capacity, and capacity turned out not to be the constraint.
The only way into block RAM is the gp rect write port, and gp measures 3.19 MB/s
on hardware. A 320x240 frame in RGB565 is 153,600 bytes: 48 ms to fill, about 21
frames a second. Sixty needs 9.2 MB/s, nearly three times what the transport
gives, and f2sdram does not help -- that is the fabric reading DDR3, not a route
into on-chip memory.

So the on-chip path is a bring-up and fallback tier rather than a delivery one.
It comes up holding a preloaded pattern and needs no memory controller, no
software and no host, which makes it the right thing to prove the scanout
pipeline against and the right thing to fall back to. It is not where host pixels
land.

Everything a host sends goes to HPS DDR3 over f2sdram, at any resolution. Its
latency is absorbed by the double-buffered line buffer in front of scanout, which
measures 160 beats a line with no underruns at 640 wide.

Bandwidth is the reason RGB565 stays on the list. A full 640x480 frame in RGB888
at 60Hz is 55 MB/s, past what USB 2.0 bulk will carry. The 240p modes sit well
inside it -- 384x224 in RGB565 is 10 MB/s full-frame -- and damage rects cut the
real figure further for anything short of full-screen motion.

## The idle screen

This is what appears from power-on until a host turns up. Enough to work out
what is wrong without a serial cable:

```
BLITSCRT_MISTER
FABRIC  NO HPS YET

MODE   640X480I 60.00HZ
LINE   15.750 KHZ
PIXEL  12.600 MHZ
H 60/76/640/24   HTOTAL 800
V 3/16/240/3 PER FIELD  525 LINES

USB    NO HOST
OUT    VGA RGB666 + HDMI DV
```

`PER FIELD` on that line matters. Everything vertical is per field. An
interlaced mode therefore shows 240 active lines under a 480-line name. The
two fields interleave: 3+16+240+3 = 262 per field, and 2x262+1 = 525 frame
lines, the odd line carrying the interlace offset. Without the label it reads
as a contradiction.

`tools/gen_banner.py` computes every number from the same timing values the
mode table carries. The screen cannot claim something the fabric is not doing.

`banner.hex` holds four banks of 16 rows: one per mode, plus a fabric-only banner in bank 3 shown when the HPS heartbeat is stale. and the
overlay picks the bank from the live mode. I had it baking a single block at
first, which cheerfully reported mode 0's numbers no matter what was on screen
once the modes went runtime.

The text lives in `char_ram.v` and comes up with no software running. At M2 the
HPS gets a write port onto the same buffer and the `USB` line becomes live
status.

Mode was a compile-time macro in M1. It is runtime now: the mode table drives the
raster until software claims it with `CTRL`'s `HPS_TIMING` bit.

## Verified in simulation

Measured out of the RTL:

```
640x240p60    63.4928 us line -> 15.7498 kHz, 262 hsync/frame, 153600 pixels

640x480i60    63.4928 us line -> 15.7498 kHz, 33.3338 ms frame -> 29.9996 Hz
              525 hsync/frame, 307200 active pixels, xpos 0..639, ypos 0..479
              hsync jitter 0.000000 us over 1200 lines
              vsync-to-hsync gap: even field 0.0000 us, odd field 31.7464 us

640x480p60    31.7456 us line -> 31.5004 kHz, 16.6665 ms -> 60.0005 Hz
              525 hsync/frame, 307200 active pixels

ADV7513 init  47 transactions decoded off the bus, 0 errors
              device address byte 0x72, first 0x98=03, last 0xFA=7D

mode select   analog board fitted        -> 640x480i (default)
              BTN_OSD once, twice, wrap  -> 640x480p, 640x240p, 640x480i
              HDMI only, no analog board -> 640x480i

scanout       28 checks: RGB565/RGB888/XRGB8888/RGB332 unpack to RGB666,
              address generation, pixel and line replication, bounds clamp,
              and one-clock latency matching the test card
rect port     seek, one-per-word advance, readback, then a rect written from
              the bus domain appearing at the right raster coordinates and
              nowhere else; geometry staged and latched only on APPLY
line fetcher  18 checks against a memory model with latency and bubbles:
              base + y*stride, beat counts per format, burst splitting,
              column readback, no underrun
register map  the 0x1000 aperture cannot reach CTRL, H_SY or H_BP
pll reconfig  the real Intel IP driven through the real bridge: MODE writes
              and reads back, and a full reconfiguration sequence reports
              STATUS ready after START
```

Eight testbenches, plus four software test binaries covering the PLL solver, the
reconfiguration sequence, the mode list and the GUD request handling. `make lint`
elaborates both scanout configurations; `make check-clk`, `check-pins`,
`check-decl`, `check-ip` and `check-fit` catch the classes of mistake that
otherwise reach hardware silently.

The last vsync line is the interlace check. hsync free-runs and only vsync
moves. That half-line shift is what drops the CRT raster to interleave the
fields.

PNGs in `sim/` are captured from the datapath during simulation. The interlaced
frame is both fields woven together:

![blitsCRT_Mister test card, 640x480i60](sim/testcard_640x480i60.png)

## What shows when nothing is connected

The test card. `BLITSCRT_CTRL_TESTCARD` selects between the card and scanout, and
`blitscrt_dev_on_host()` clears scanout on `FUNCTIONFS_DISABLE`, so pulling the
cable falls back to it. A stale frame left on screen would look exactly like a
crash.

The overlay tracks the same thing: `USB NO HOST`, then `USB ATTACHED` once
enumerated, then `USB STREAMING` once the controller is enabled.

## PLL reconfiguration

Counters are not written as divide values. Each splits into a high and a low
half-period so an odd divide can hold one phase a cycle longer:

```
divide 1     bypass the counter
divide even  high = low = D/2,          odd_duty = 0
divide odd   high = (D+1)/2, low = D/2, odd_duty = 1
```

Both halves are eight-bit fields, which caps any divide at 510 rather than the
512 the datasheet quotes for the counters themselves. `pll_cyclonev` in
`sw/pll.c` carries the same ceiling, because solving for a divide the hardware
cannot be told about is worse than not solving. The test found that: 511
encoded as high=255+1 and wrapped silently.

### Dynamic resolutions

Switchres generates a modeline per game, and nothing has to be told to this
device in advance. GUD hands over a **complete DRM mode** on every modeset --
pixel clock in kHz plus all eight timing values and the flag word -- not an index
into a list. So a synthesised mode needs no extra step:

```
Switchres  ->  X / DRM  ->  SET_STATE_CHECK   ->  modes.c validates,
                                                  solves M/N/C
                            SET_STATE_COMMIT  ->  PLL retuned, timing and
                                                  geometry latched, raster
                                                  handed to the host
```

A fixed list will not do, and two paths are covered:

- **Adding to the list.** `blitscrt_modelist_add()` validates and appends, then
  raises `GUD_CONNECTOR_STATUS_CHANGED`. The host re-probes the connector and
  re-reads the modes. No USB re-enumeration, which would tear down the DRM
  device and every client's framebuffer with it.
- **Setting an unadvertised mode.** DRM lets userspace set a timing that was
  never probed. `GUD_REQ_SET_STATE_CHECK` carries the full mode, and the device
  is the arbiter. `test_device` sets a 384x224 modeline that was never in the
  list and it is accepted, validated and clocked.

Refusing matters as much as accepting. A 640x480p60 mode at 31.5kHz gets
stalled with `GUD_STATUS_INVALID_PARAMETER` and the previous mode stays live.
Sending 31kHz to a 15kHz set is a repair bill. A mode is also refused rather than
approximated if no M/N/C lands inside the VCO band at a tight enough tolerance --
the device has to be able to make the clock, not merely tolerate the timing.

One unknown, and it sits on the host side. GUD's kernel driver may filter modes
through DRM's `mode_valid` before they reach the device, in which case a
synthesised mode could be rejected upstream and never arrive. That cannot be
settled without a host attached, so M4 is what will show it.

### Register file

`rtl/blitscrt_regs.v` implements the map in `sw/blitscrt_regs.h` as an
Avalon-MM slave in the 50 MHz bus domain, with the video side on whatever the
pixel clock currently is. Two crossings live in it.

Timing moves as a **block**, not register by register. Writing `APPLY` toggles a
request; the video side latches all nine values at the next vblank and
acknowledges. A modeset therefore cannot land half-applied, and cannot tear.
`STATUS` carries an `APPLYING` bit so software can tell the difference between
"queued" and "live".

Status comes back through two-flop synchronisers, which is enough for bits
nothing sequences on.

```
0x0000..0x0FFF  registers
0x1000..0x1FFF  altera_pll_reconfig
0x2000..0x3FFF  character buffer, one byte per word
```

### Register contract

`sw/blitscrt_regs.h` is the interface between the daemon and the fabric.
Timing registers use the same four-part decomposition the RTL is parameterised
with, and `test_device` asserts that a DRM `640x240p60` mode converts to
exactly the `H 30/32/320/24 V 3/16/240/3` compiled into `blitscrt_top.v`.

Timing and PLL values are staged and latched together on a vblank. A modeset
never shows a partial frame at a half-applied timing.
