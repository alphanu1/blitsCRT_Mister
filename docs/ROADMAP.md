# Roadmap and status

The milestone history, in detail: what each one covers, what is done, and what
was learned getting there. The README carries the summary.

**Current bugs are at the top, deliberately.** The milestone history below is
long and mostly settled; what needs attention is here. One open, and it is not
yet investigated.


## Open bugs

### Stray pixel lines in the Donkey Kong 64 intro -- not investigated

Beside two of the heads. No code written for this.

Worth capturing `peek -g` with it on screen, for `late lines` and `underruns`,
and establishing whether it is N64-wide or only that scene: the intro is
pre-rendered video, so it may be a decode path the emulator uses nowhere else,
which would put it host-side rather than here.


## Done, awaiting confirmation on hardware

**Stale pixels outside the new active area are gone.** On a mode change the
scanout geometry shrank but DDR3 still held the larger picture, and nothing
cleared what the new mode did not cover -- so the edges showed the previous
frame as garbage. Seen directly during debugging: a RetroArch menu survived a
full-frame black fill at a smaller geometry.

Fixed as a side effect of the blanking below. `blitscrt_fabric_enable()` clears
the window when it blanks, and a host disables the controller on every mode
change -- so in practice the clear happens on the way through every switch.
Confirmed on hardware.

A geometry change with the controller left enabled would still not be covered.
Nothing does that today; if something ever does, the fix is the same clear in
`blitscrt_scanout_configure()`.

**The test card no longer flashes between modes.** A host disables the
controller on every mode change, and the card used to appear for a fraction of a
second each time. Scanout now blanks instead, and the card returns only after
three seconds idle -- long enough that a mode change never reaches it, short
enough to answer "is it alive?" when a cable comes out.

Black has to come from the framebuffer, because the fabric shows the card
whenever scanout is off:

```verilog
src_scanout = r_scanout_en && !r_testcard_en;
```

Both bits clear is still the card. So scanout stays enabled over a cleared
window. `BLITSCRT_TESTCARD_DELAY_MS` in `device.h` if three seconds is wrong.


**M8 -- vblank in gud. Not started.** The driver reports no vblank at all, so an
application asking to synchronise to this display gets nothing to synchronise
to. Measured with vsync on and nothing else attached: 186 frames/s against a
59.99 Hz raster, 128 against 59.82, 95 against 59.83. The host is not being
paced, frames land in DDR3 mid-scan, and two thirds of what it renders is
overwritten before it is displayed.

DRM has a standard answer -- an hrtimer at `framedur_ns`, as vkms, virtgpu,
vmwgfx and amdgpu's virtual display all do -- and there is work in flight to
move it into the core as `DRM_CRTC_VBLANK_TIMER`.

But every driver using that pattern is guessing, because none of them have a
real raster. **This one does.** A free-running timer on the host would drift
against a fabric generating exact timing, which is the thing this project goes
to some lengths to avoid. So the timer is the first step and not the end of it:
either discipline it against a frame counter read back from the fabric, or send
a real vblank event over the wire and call `drm_crtc_handle_vblank()` on
arrival.

The second needs a GUD protocol addition, which is the significant part -- GUD
is a wire protocol with other implementations, so an event channel is not
something to add casually.

`docs/VBLANK.md` has the callbacks needed, the ordering trap in the timer
callback, and what each option costs.

**M7 -- Windows host. Not started, and probably not here.** GUD is a wire
protocol, not a Linux one: request codes, a mode structure, a buffer format.
Nothing about the board depends on what is at the other end, so a Windows host
that speaks the same protocol works against this hardware unmodified.

That cuts both ways, and is the reason M7 belongs in its own repository with a
link from here rather than inside this tree. A Windows GUD driver is not specific
to blitsCRT in any way: it would drive a Pi Zero adapter, the STM32 reference
device, or anything else implementing the protocol. Burying it in an FPGA CRT
project would make it hard to find and hard to reuse, and would tie its release
cycle to hardware it does not care about. The protocol is open by design -- "all
that's needed is to add a USB vid:pid" -- so a host driver is a peer of the Linux
one, not an accessory to this board.

Nothing like it appears to exist. The GUD ecosystem is entirely Linux: the in-tree
driver, the gadget side, Raspberry Pi images. The IddCx samples that do exist are
all *virtual* displays -- they enumerate a monitor and discard the frames -- so the
frame loop is demonstrated but the transport is not. Two references make it new
work rather than a blank page. The GUD host driver is **deliberately MIT
licensed**, in the author's words "to smooth the path for any BSD port", so its
protocol logic is both readable and reusable. And Microsoft ships an IddCx sample
for the Windows plumbing. The novel part is the join between them.

| | |
|---|---|
| done | the protocol is host-agnostic; the device side needs no change for this |
| **todo** | **stand it up as its own project and link it from here; it is useful to any GUD device** |
| **todo** | **an IddCx user-mode driver, starting from Microsoft's sample** |
| **todo** | **establish how a modeline reaches the driver; IddCx carries resolution and refresh, not porches** |
| todo | most likely a Switchres backend for this driver, alongside its existing drmkms and adl ones |
| todo | damage tracking from the desktop surface, which the Linux driver does for free |
| todo | format conversion to RGB888 or RGB565 in the driver |
| todo | driver signing: test-signed for a cabinet, attestation-signed to distribute |

The framework is IddCx, the Indirect Display Driver class extension: user-mode
only with no kernel component, running in Session 0, handed the desktop image as a
DirectX surface. Microsoft names this exact case -- a USB dongle with a monitor
attached -- and ships a sample that enumerates a monitor and runs the frame loop.

Switchres stays where it is, in the emulator, as on Linux. What differs is how its
output reaches the display. On Linux it adds the mode to DRM and GUD carries the
whole modeline through `SET_STATE_CHECK`. Windows has no equivalent path: IddCx
deals in a monitor mode list and EDID, so resolution and refresh reach a driver and
porches do not. A normal indirect display does not generate its own timing and has
no use for them. This one does.

The existing Windows arrangement is a two-part one. A tool installs the resolution
list into the driver ahead of time, and the emulator then adjusts timings at run
time through a driver-specific interface -- ADL on AMD -- so every refresh rate
does not have to be predefined. The first half maps straight onto IddCx, which
reports a mode list already. The second half has no IddCx equivalent and is the
real work of M7.

Switchres has a pluggable backend for exactly this reason, with `drmkms` on Linux
and `adl` and `powerstrip` on Windows, so another one for this driver is the shape
the problem already has. That is the expected route rather than a settled one:
where a Windows Switchres deposits a generated modeline, and whether it can be
read rather than pushed, is the first thing M7 has to establish.

Screen capture through the Desktop Duplication API would be a fraction of the
effort and is not an option: it cannot switch resolution per game, which is the
point of the whole design.



**M1 -- fabric only. Done.** Running on hardware: 15kHz output, both connectors
live.

| | |
|---|---|
| **done** | **15kHz confirmed on hardware: 640x480i60 at 15.750 kHz, over HDMI** |
| done | 15kHz timing, progressive and interlaced, measured out of the RTL |
| done | three built-in modes, runtime selection, detection, button cycling |
| done | timing generator takes porches and geometry as inputs, not parameters |
| done | test card, text overlay, font and banner generation |
| done | ADV7513 setup over a fabric I2C master, 47 writes decoded |
| done | pin assignments verified against MiSTer, every port covered |
| done | analog RGB666 and HDMI driven from the same pixel stream |

**M2 -- custom kernel and runtime control. Done.** The BlitsCRT kernel boots on
hardware, the daemon reads and drives the fabric over the gp transport, and the
live overlay -- mode, line and pixel rates read back from the raster itself, with
an HPS-up heartbeat holding it on screen -- is running.

![M2 on hardware: the daemon driving the live overlay, HPS up, reporting the real 480i60 timing](docs/images/blitscrt_m2_hps_up.png)

| | |
|---|---|
| **done** | **daemon reads the fabric version over gp, runs the heartbeat, drives the live overlay on hardware** |
| done | the BlitsCRT kernel boots, mounts the card, writes the boot log |
| done | dedicated u-boot boot: env programs the fabric and boots our kernel |
| done | embedded initramfs: static init + busybox, exFAT/FAT mount, serial shell |
| done | init launches `blitscrtd --no-gadget` on boot |
| done | gp bridge: read-latency, 32-bit half-select, and strobe CDC, verified in `tb_bridge` |
| done | `blitscrt-peek` register tool for bring-up (read / write / beat) |
| done | Avalon-MM register slave `rtl/blitscrt_regs.v`, PLL and reconfig IP wired in |
| done | clock crossing: timing latched as a block on vblank, status resynced |
| done | heartbeat watchdog and host-state hint; `hps_alive` drives the overlay bank |
| done | GUD control endpoint (15 requests), mode validation, PLL solver (6 ppm worst case) |
| done | gadget stack built into the kernel (dwc2 dual-role, FunctionFS, configfs) -- for M4 |

The daemon writes its banner into all three overlay banks so it shows whatever
mode the front panel has selected, and reports the timing the raster is really
running -- read from `LIVE_*`, which is post-mux, rather than from the staged
registers, which describe what was asked for. `blitscrt_fabric_open()` is the seam; the daemon builds
static for ARM and runs from the initramfs, or from a swappable copy on the card.

**M3 -- scanout memory. Done.** Pixels live in HPS DDR3 and the fabric fetches
them a line at a time over f2sdram. Confirmed on hardware at 640x480: 160 beats a
line, no underruns, and a rect written at 78 MB/s by `memcpy` with the register
bus never touched. Custom pixel clocks work -- PAL 640x576i50 at 12.500 MHz, a
clock the fabric was never compiled with, reached by reconfiguring the PLL with
timing, geometry and ownership following it.

| | |
|---|---|
| **done** | **640x480 scanned out of HPS DDR3 over f2sdram on hardware: 160 beats a line, zero underruns** |
| done | `scanout.v` unpacks RGB565 / RGB888 / XRGB8888 / RGB332 to RGB666, one clock, matching the test card |
| done | source mux off `CTRL`; the five control bits stubbed through M2 are live |
| done | pixel and line replication derived from geometry, giving a true 320-wide active area back |
| done | on-chip M10K path (`scanout_ram.v`), preloaded so scanout works with no software at all -- a bring-up tier, not a delivery one: gp cannot fill it at 60 Hz |
| done | rect write port: `SCANOUT_WADDR` seeks, `SCANOUT_WDATA` advances, one gp command per pixel |
| done | `scanout_fetch.v` bursts a line into a double-buffered line buffer; raw beats, lane select on read |
| done | `sysmem_lite` lifted from MiSTer; word-address and burstcount adaptation in `blitscrt_f2sdram.v` |
| done | `SCANOUT_SRC` selects on-chip or DDR3; `scanout.v` is identical either way |
| done | `CAPS` reports which, because the two need different write paths and choosing wrong fails silently |
| done | `SCANOUT_GEOM` writable and latched with the timing set; geometry moves with the mode |
| done | `SCANOUT_DIAG`: beats moved for the last line, saturating underrun count |
| done | daemon maps the reserved DDR3 window; `blit()` and `fill()` route on `CAPS` |
| done | raster obeys the daemon's timing on `CTRL_HPS_TIMING`, front-panel table when clear |
| done | 0x1000 aperture no longer aliases the register file; `tb_regs` holds it to account |
| done | measured: gp 3.19 MB/s, uncached DDR3 writes 110 MB/s by `memcpy` |
| done | PLL reconfig window reads and writes, verified against the real Intel IP in `tb_pll_reconfig` |
| done | a reconfiguration completes on hardware and the PLL retunes |
| done | custom clocks reachable from a modeset: PAL 640x576i50 at 12.500 MHz on hardware |
| done | every mode then advertised was reachable, three of them needing reconfiguration |

*Why DDR3 rather than more block RAM.* The pixels are already there: the gadget
receives into DDR3, so the fabric goes to them instead of software pushing every
pixel across a bridge. Measured on hardware, the ARM writes that window at
110 MB/s by `memcpy` against USB 2.0's ~35 MB/s ceiling, and row-granular copies
cost the same as one large one, so a narrow damage rect is not penalised. The gp
transport manages 3.19 MB/s, which settles what it is for: control, never pixels.

`scanout_fetch.v` bursts one line into a double-buffered line buffer while the
raster reads the other. The buffers hold raw bus beats and lane selection happens
on the read side, so the fetch path is format-agnostic -- it moves bytes and never
learns what a pixel is. Double buffering is not for throughput; a line is 1280
bytes against 63.5 us. It is there so a late burst cannot swap a buffer under the
raster.

`rtl/mister/sysmem.sv` is MiSTer's, lifted whole. It is not a Platform Designer
project but a flattened system checked in as SystemVerilog, so there is nothing to
generate. Using theirs also matters because the f2sdram port configuration is
latched by `APPLYCFG` while the SDRAM interface is idle -- the preloader's job at
boot, and impossible from Linux -- so a different configuration would not match
what is already latched.

`SCANOUT_SRC` picks where pixels live, in the same spirit as `BRIDGE` on
`blitscrt_bridge`: one place knows and nothing downstream changes. Only one memory
is instantiated, so a DDR3 build gets back the 43% of M10K the on-chip picture
used.

Software reads what it is talking to rather than assuming. `CAPS` reports which
scanout source the bitstream has, because the two need different write paths and
choosing wrong fails silently. `SCANOUT_GEOM` is writable and latches with the
timing set. `SCANOUT_DIAG` reports beats moved for the last line and a saturating
underrun count, and `LIVE_*` reports the timing `video_timing` is actually being
fed -- which is what `blitscrt-peek -t` decodes, and what `set_mode()` confirms
against rather than trusting a status bit.

*Timing ownership.* The raster obeys the daemon's timing when `CTRL`'s
`HPS_TIMING` bit is set and the front-panel mode table when it is clear. Clear at
reset, so a picture exists before any software runs, and clearing it is the way
back from a mode the display cannot show -- which works because gp runs on the
50 MHz reference and stays reachable whatever the pixel clock is doing. That
matters with `BTN_OSD` dead on this board.

**M4 -- GUD USB host link. Done.** The board appears to a host PC as a
plug-and-play display, with no driver to install. Confirmed on hardware:
`1d50:614d` enumerates, the in-tree `gud` driver binds, a `/dev/dri/card*`
appears, and the desktop is on a 15 kHz CRT hanging off an FPGA -- wallpaper,
taskbar, menus, at 640x480i60 and 15.750 kHz.

| | |
|---|---|
| done | GUD control endpoint, 15 requests, mode validation, PLL solver, `test_device` coverage |
| done | gadget stack in the kernel: dwc2 dual-role, FunctionFS, configfs |
| done | modeset path end to end: PLL, timing, geometry, ownership, confirmed against `LIVE_*` |
| done | every mode then advertised solved and applied; `modelist_add` refuses anything `mode_check` would reject |
| done | unadvertised modes accepted and applied, so Switchres needs no extra step |
| done | a failed modeset is reported to the host as one; it used to answer OK regardless |
| done | `blitscrt-peek -m` applies a modeline through the same path a host uses |
| done | `gadget-setup.sh` creates the configfs gadget and mounts FunctionFS; init runs it before the daemon |
| done | `tools/set_dr_mode.py` patches the built dtb to peripheral mode; the stock tree leaves `dwc2` in host mode and `/sys/class/udc/` empty |
| done | init stages the gadget, then launches `blitscrtd` with it, falling back to `--no-gadget` if FunctionFS did not come up |
| done | **a host enumerates it as a GUD display.** Confirmed on hardware: `1d50:614d`, `gud 1.0.0` bound, `/dev/dri/card*` created |
| done | changing mode from the host works. It used to hang both ends -- the same read-size fault, since a modeset produces a differently sized flush |
| done | the overlay hides itself while a host is attached and comes back when one leaves; the front-panel button stays authoritative |
| note | no EDID sent, so the connector reads `VGA-1-unknown`. Both variants tried on hardware break mode selection; the likely reason is that they contain no timings at all. See the limitation below |
| done | composite sync, on `CTRL` bit 3 and on by default. Tested on a television through SCART, which is the case that needs it -- and needed the broadcast waveform rather than `hs ^ vs`: half-line serration through vertical sync and equalising pulses either side, or the picture rolls. `tb_csync.v` asserts the pulse counts and widths |
| done | **pixels on screen.** The bulk endpoint drains a full frame per flush and blits it into scanout |
| done | A-to-A cable with VBUS cut into the Type-A OTG port, with the USB hub add-on removed |

*A modeset that failed used to report success.* The commit path set
`active_valid`, called `blitscrt_fabric_set_mode()`, discarded the return value
and answered `GUD_STATUS_OK` unconditionally -- so a reconfiguration that timed
out, a geometry that did not take, or a raster running something else were all
reported to the host as a successful modeset, and the daemon then believed it was
driving a mode it was not. `set_mode()` confirms against the live registers so
that its answer means something; throwing it away wasted that. It now applies
first, leaves `active_*` alone on failure so the overlay keeps describing what is
really on screen, and returns `GUD_STATUS_PROTOCOL_ERROR`.

*The bulk endpoint used to drain transfers without writing pixels.* It counted
them so the host stayed happy and the rect never reached memory, so a host would
enumerate, modeset, negotiate a format and stream frames while the screen did not
change. Fixed: `blitscrt_scanout_blit()` takes exactly the x/y/w/h a GUD
`set_buffer` request carries and routes itself.

*What it took, and the two that mattered.* The bulk endpoint delivered nothing for
a long time while the entire control protocol worked -- descriptors, formats,
connectors, modes, modeset, `SET_BUFFER`, every one answered with status 0. Two
faults, both structural:

**The endpoint needs its own thread.** A read on a FunctionFS endpoint blocks
until the transfer completes, and doing that on the ep0 thread means no control
request can be answered while a frame arrives. If the host issues one during its
flush, both sides wait on each other -- an indefinite hang with no timeout at
either end. Linux's own `ffs-test.c` runs a thread per endpoint for exactly this
reason. `bulk_worker` now does, and fabric access is serialised with a mutex,
since the gp transport carries a strobe parity across calls.

**Gadget FIFO sizes were never set.** The stock socfpga node has none, being
written for host mode, and dwc2's defaults left the bulk endpoint with nothing
behind it -- an endpoint with nowhere to put data NAKs rather than stalling, so
nothing errors. `set_dr_mode.py` now sets `g-rx-fifo-size`, `g-np-tx-fifo-size`
and a `g-tx-fifo-size` entry for all 15 endpoints; dwc2 rejects a short list
outright, which is how the second attempt was caught.

Also ruled out along the way, each on hardware: the endpoint descriptor (`lsusb
-v` shows `EP 1 OUT`, bulk, 512 bytes), the modeset, transfer size, `O_NONBLOCK`
(worse -- a read is what queues the request, so `EAGAIN` means nothing is ever
offered), and compression.

**M5 -- bandwidth. Done; only RGB888 remains, and that is depth not rate.** The worst case is
a full surface every refresh, which full-screen motion produces, and only the
640-wide modes exceeded the link there -- by about five per cent. LZ4 closed it:
RetroArch full-screen at 640x480i60 went from **51.98 fps to 60.01**, which is the
vsync cap rather than a limit. Measured 2.57x on a desktop and 253x on a static
screen, against the 1.2x the arithmetic needed.

What remains is depth rather than rate. RGB888 is still not offered, and 24kHz and
31kHz add more 640-wide modes.

| | |
|---|---|
| done | RGB332 implemented, and halves everything at no CPU cost |
| done | damage rectangles, which carry anything short of full-screen motion |
| done | LZ4 offered and decompressed. `sw/lz4dec.c`, block format, every read and write range-checked |
| done | on by default in the daemon itself, so it applies however it is started; `BLITSCRT_LZ4=0` turns it off |
| done | 640x480i60 full-screen runs at 60 fps with LZ4, 51.98 without |
| done | measured on real traffic: 2.58x on a desktop, 253x on a static screen. LZ4 reaches 60 fps |
| done | LZ4 stable: read requests rounded to a packet boundary, so a transfer neither splits nor swallows the frames behind it |
| done | the read overlaps the decompress and blit: two threads and a two-slot pool, so a frame costs `max(read, lz4 + blit)` |
| done | decompression costs 3.3 ms for a 640x480 RGB565 frame, 186 MB/s of output. Small offsets use a doubling copy rather than a byte loop -- 1.37x on x86, more on the A9 |
| done | measured on real traffic: 2.58x sustained, 253x on a static screen, and the daemon reports achieved fps against the frame budget |
| **todo** | **a two-beat read window in `scanout_fetch.v`, so RGB888 works -- the only deep format that fits 640-wide with LZ4** |
| note | RGB888 as a *source format* is separate from 8-bit *output*. The pipeline is RGB666 end to end: `scanout.v` truncates an 8-bit source to six, and only `VGA_R/G/B[5:0]` reach the DAC. Eight-bit output needs all three -- the source format, the pipeline widened, and the DAC's low two bits per channel driven on `SDIO_DAT[3:0]`, `SDIO_CMD` and `SDIO_CLK`, which MiSTer sends as `{vga_g,vga_r,vga_b}`. Any one alone changes nothing visible |

Measured on hardware. Raw, RetroArch full-screen at 640x480i60 runs **51.98 fps**;
with LZ4 the same content reaches **60.01**, the vsync cap, at 2.58x compression.

The daemon reports its own achieved rate as well, which is worth using in
preference to a host-side counter -- it also prints where the frame time goes, so
a shortfall can be attributed rather than guessed at. Note that the device is
rarely the limit: it uses roughly 9 ms of a 16.7 ms budget, so `critical path`
well under `available` means the frames are not arriving, and the cause is
upstream. A flaky USB hub on the host produced exactly that, and no amount of
work on this side would have helped.

*Getting the read size right took three attempts, and both obvious answers are
wrong.* There is no framing on the bulk stream to resynchronise against --
`gud_set_buffer_req` says how many bytes follow, and if that count is ever out by
one transfer, every rect afterwards decodes against the wrong length.

Ask for exactly `compressed_length` and the kernel splits a transfer that arrives
slightly larger, leaving the remainder queued:

```
functionfs read size 9725 > requested size 9645, splitting request into multiple reads.
```

Ask for the whole buffer and the opposite happens -- one read returns everything
queued, spanning many rects:

```
read 1048576, header said 4741
```

Rounding up to a packet boundary is the answer: enough slack to absorb a padded
transfer, not enough to reach the frame behind it. LZ4 is on by default;
`BLITSCRT_LZ4=0` turns it off.

*Where the frame time goes*, measured with the breakdown the daemon prints:

```
read 1.5 ms   lz4 2.6 ms   blit 5.6 ms   total 9.5 ms   (16.7 available)
read 4.9 ms   lz4 4.3 ms   blit 5.6 ms   total 14.7 ms  worst seen
```

The blit is the fixed cost -- 614400 bytes into the uncached DDR3 window at about
110 MB/s, every frame whatever the content. Decompressing straight into that
window does not help: LZ4 emits short scattered writes, the worst case for
write-combining, which is the 69-against-110 MB/s gap measured on this board.

Serially in one thread that left about two milliseconds of margin at worst, and
jitter cost a frame -- 58.5 rather than 60. The read now runs on its own thread
with a two-slot pool between, so it overlaps the decompress and blit of the frame
before: a frame costs `max(read, lz4 + blit)` rather than the sum, and only the
latter is on the critical path.

Three threads, and the shape matters. The reader touches only the endpoint and
the pool; the processor touches only the pool and the fabric; ep0 stays free
throughout. The slot indices are never reset, only incremented -- clearing them on
host detach let the processor's release overshoot, and an unsigned difference
wrapping to a huge number made the reader believe the pool was permanently full.
That hung the daemon on unplug and was found by reading the code rather than by
running it.

RGB565, a full surface every refresh, against about 35 MB/s of bulk in practice.

```
                                    MB/s          of budget
                                 raw    LZ4     raw     LZ4
256x224p60   NES, SNES, CPS      6.9    3.4     20%     10%
320x224p60   Genesis, arcade     8.6    4.3     25%     12%
384x224p60   CPS2, Neo Geo      10.3    5.2     29%     15%
320x240p60   advertised          9.2    4.6     26%     13%
320x288p50   PAL 240p            9.2    4.6     26%     13%
640x480i60   PSX hi-res, PC     36.9   18.4    105%     53%
640x576i50   PAL hi-res         36.9   18.4    105%     53%
640x480p60   31kHz              36.9   18.4    105%     53%
```

Almost the whole retro catalogue is 240p and lands around a quarter of the budget
raw, full-screen motion and every pixel changing. The 640-wide modes are the only
ones over, and only in this worst case: they run today, and damage rects keep the
real figure below the table for anything that is not full-screen motion. With LZ4
every mode sits at half the budget or less.

Interlacing saves nothing on the wire. GUD carries rects in the mode's coordinate
space and DRM's `vdisplay` for 480i is 480, so the host sends the whole progressive
surface and the device interleaves on read. What interlacing halves is what the
CRT draws per field, not what crosses USB.

That five per cent is why LZ4 is the right lever rather than pixel depth. The usual
objection -- that it collapses to 1.1x on full-screen motion -- assumes photographic
content: noise, grain, continuous gradients. Sprite-based output is flat colour
fields and repeated tiles drawn from small palettes, so it should compress
considerably better. **The 2x in the table was an assumption; the measurement came
in at 2.57x on a desktop**, so if anything it was conservative.

The case never rested on it, and the margin was the reason. 640x480i60 needs
36.9 MB/s raw against about 35, so **1.2x clears 60 fps** -- and 1.2x is roughly
the figure for photographic video, all noise and continuous gradient. Sprite work
is flat fields and repeated tiles from a small palette; if LZ4 managed only 1.2x
on that it would be doing something wrong. The required ratio sits below the
pessimistic floor for this content, which makes the decompressor worth building
before the ratio is measured rather than after. Measuring it then says how much
headroom there is, not whether it worked.

*Colour depth.* The ladder is six bits a channel, so RGB565 gives away a bit on
red and blue. Full depth costs more wire, and where that matters is narrower than
it looks:

```
                              raw     of budget      LZ4     of budget
384x224p60   RGB565          10.3        29%         5.2        15%
             RGB888          15.5        44%         7.7        22%
             XRGB8888        20.6        59%        10.3        29%
640x480i60   RGB565          36.9       105%        18.4        53%
             RGB888          55.3       158%        27.6        79%
             XRGB8888        73.7       211%        36.9       105%
```

Every 240p mode carries the full ladder raw, no compression needed -- RGB565 buys
nothing there and costs a bit of red and blue. It is the 640-wide modes where
depth has a price.

And there the fourth byte decides it. `RGB888` at three bytes fits with LZ4 at
79% of budget; `XRGB8888` at four does not, needing better than 2.1x rather than
2x. So RGB888 is both the format that wastes no ladder depth and the only deep one
that fits a 640-wide mode at all.

It is also the one `scanout_fetch.v` cannot read: three bytes straddles the 64-bit
beat boundary, and the lane extractor handles 1, 2 and 4-byte formats. A two-beat
read window fixes it -- hold the previous beat alongside the current one so a pixel
spanning bytes 6, 7 and 8 can be assembled. Contained to the read side, with
`scanout.v` and everything upstream unchanged, and it is what turns full depth from
advertised into working.

The cost is a decompressor on the ARM and a second pass over the data. Decompress
into a cached buffer, then one `memcpy` to the uncached window: LZ4 emits short
scattered literal and match copies, the worst case for write-combining, which is
the 69-against-110 MB/s gap measured on the board.

Before any of that, one measurement may remove the problem. A CRT shows a complete
480i frame thirty times a second, so sending sixty full surfaces is twice the work
for something physically invisible. At frame rate it is 18.4 MB/s, full colour, no
decompressor. Whether a host can be persuaded to do that is a DRM question and M4
will answer it.

**M6 -- front panel and soft disconnect. Done.** Buttons, LEDs, and a way to take
the display away from a host without touching the cable.

*Where the front panel actually is.* On a board with the newer A/V board the
`BTN_*` pins carry nothing and the `LED_*` pins carry the DAC's clock, blank and
sync. All six are behind an **MCP23009 I2C expander** on a bus bit-banged in the
fabric -- not HPS I2C, which is why looking in `/sys/bus/i2c` on the ARM finds
only the RTC board.

The pins are `IO_SCL` on `PIN_U14` and `IO_SDA` on `PIN_AG9`, from MiSTer's
`sys/sys.tcl` under a heading that reads "I2C LEDS/BUTTONS". Worth noting they are
*not* in `sys_analog.tcl`, which is where the LED and button pins themselves live
and the obvious place to look.

*Two things about the expander that were got wrong first.* Its outputs are open
drain, so writing 0 lights an LED and writing 1 releases it -- an active-high
signal has to invert on the way out, and backwards it lights all three at the
wrong moments, which reads as three separate faults. And it reports
`{GP5, GP4, GP3}` = `{OSD, reset, user}`, so bit 0 is user and bit 2 is OSD;
swapped, each button does another's job.

*The user button.* Pulling the cable leaves the last frame frozen, because the
revert to the test card is driven by `FUNCTIONFS_DISABLE` and dwc2 raises that
from VBUS going away -- which the A-to-A cable, VBUS cut on the board side, never
sees. On X11 a host can panic outright when a live output disappears underneath
it. Unbinding the UDC does raise the event, so the whole detach path runs
properly, and it stays disconnected until pressed again so the cable can stay in.

The press is latched in the fabric at `BTN_EVENT` and consumed by the daemon,
write-one-to-clear so a `blitscrt-peek` cannot steal it. It latches on the falling
edge with a hold-off: it set on the level at first, and since a press outlasts the
daemon's poll interval, the daemon cleared it and the still-held button set it
again -- one press toggling the connection two or three times, which read as an
unreliable button rather than a bug in the latch.

*The LEDs.* Power on PLL lock; user green when the display is available, disk
orange when it is not. Complementary rather than two views of the same thing,
which is what having two colours is worth -- they tracked "bound" and "host
attached" separately at first, which reads well written down and badly on a panel,
since both were lit whenever anything was connected.

| | |
|---|---|
| done | `IO_SCL` on `PIN_U14` and `IO_SDA` on `PIN_AG9`, from `sys/sys.tcl` under "I2C LEDS/BUTTONS" |
| done | `mcp23009` instantiated, `present` selecting between it and the GPIO pads; `IO_DIAG` and `blitscrt-peek -i` report which is in use |
| done | reset works; OSD shows and hides the overlay. It inverts what the daemon asks for rather than being ANDed with it, so a press brings the text up over a host's desktop -- which is where it earns its keep, since it reads the timing back from LIVE_* and says what the raster is really running |
| done | `BTN_EVENT` at 0xA4 latches a user-button press on the falling edge with a hold-off, write-one-to-clear |
| done | the user button toggles the connection: unbind the UDC, revert to the test card, and stay that way until pressed again |
| done | LEDs: power on PLL lock, user green and disk orange complementary on whether the display is available |
| note | pulling the cable is still not detectable, since VBUS is cut. `/sys/class/udc/<name>/state` reports `configured` independently of the FunctionFS event stream and would catch it |

**Switchres modes at boot was M6 and has been dropped.** The idea was to read a
monitor profile at startup and generate a curated list of advertised modes from
it. It is the wrong shape for this device: GUD asks for the mode list once during
enumeration and takes what it is given, so a generated list is fixed for the
lifetime of the connection -- while Switchres on the host computes a modeline per
title and sets it through `SET_STATE_CHECK`, which never consults the list at all.
A long advertised list competes with that rather than helping it. One fallback
mode and an unrestricted `SET_STATE_CHECK` path is the better arrangement, and is
what the daemon does now.

What was worth keeping from it is the safety argument. A fixed-frequency
deflection circuit can be damaged by sync outside its band, so `mode_check()`
clamps against `blitscrt_limits_15khz` on every timing a host sets, advertised or
not. Widening that band for a multisync should stay a deliberate act.

## Interlace at 60 Hz

Some kernels rate an interlaced mode at its field rate and render 60 frames a
second; others rate it at the frame rate and render 30. Measured on the same
daemon, same distribution, same X11:

| kernel | desktop | 320x448i |
|---|---|---|
| 7.1.6-arch-1-1 | XFCE, Intel Iris | 60 fields/s |
| 7.1.5-zen1-2-zen | Plasma (compositing on or off), RX 9070 XT | 30 fields/s |

Where it halves, nothing on this side can change what X tells an application --
but it can change what the application is asked for. `mode_check` rewrites a
**31 kHz progressive** mode into a 15 kHz interlaced one, so the host allocates a
full-height surface, renders at the full rate because nothing told it the mode was
interlaced, and the fabric interleaves on the read. Each field then comes from a
different render, which is what an interlaced console does.

No fabric changes: `video_timing.v` already interleaves. The conversion fires only
for progressive modes out of band whose half is in band, so an interlaced mode
passes through untouched and a machine that does not need this never sees it.

| | |
|---|---|
| done | the rewrite, with the clock solved from the wanted field rate rather than halved -- an interlaced frame is 2*field+1 lines, so an even host total does not halve cleanly and exactly half runs 1912 ppm slow |
| done | the clock carried in Hz, not the mode's integer kHz, which was costing 75 ppm on its own |
| done | a warning when the converted hsync is the wrong width, since horizontal porches pass through unchanged and only halve correctly if the 31 kHz profile carries half the times |
| note | not the compositor -- the PC halves it with KWin on and off. Two candidates left, and the GPU is the more interesting: a discrete card makes the gud output a reverse-PRIME sink, which puts amdgpu in the render path and makes the 15 kHz set's amdgpu interlace patches relevant after all. `LIBGL_ALWAYS_SOFTWARE=1` would implicate or clear it. The kernel version is the weaker second candidate |

`docs/INTERLACE.md` has the reasoning and the `crt_range` lines for both profiles.


## Timing constraints on the output pads

`make check-fit` reported PASS for weeks on a design carrying **-5.641 ns of
setup slack and -214 ns of TNS**, because it read synthesis notes and constraint
coverage and never looked at slack at all.

Every failing path was an output pad:

```
From: overlay|de_out   To: HDMI_TX_D[1]   Latch Clock: n/a   Relationship: 12.000
Clock Skew : -8.932    Data Delay : 8.709
```

The 12 ns was invented and could never be met -- the pixel clock takes 8.9 ns to
reach the output registers, leaving 3.1 ns for 8.7 ns of routing. Not a
functional fault: at a 79 ns pixel period the outputs are fine, and both HDMI
and the CRT have worked throughout. But it buried the report, and a real failure
would have been invisible underneath it.

| | |
|---|---|
| done | HDMI constrained source-synchronously against the forwarded `HDMI_TX_CLK`, which is what the ADV7513 actually samples with |
| done | VGA relaxed to 25 ns with min and max, since what matters is skew between the six bits of a channel rather than absolute delay, and the DAC has no clock pin of its own |
| done | `check-fit` fails on negative slack, reports each fault once, and stops matching the report's own table of contents |
| done | `make failing-paths` names the endpoints, which the summary never does |

The registers-only report was clean throughout -- worst slack **+3.397 ns** in
`scanout_fetch` -- so the fabric itself was never the problem.


## The live raster, and why narrow modes were broken

Three places read the front-panel mode table's geometry rather than the raster
actually being scanned:

```verilog
wire [11:0] frame_h = t_hact;                    // test card width
wire        hdouble = (t_hact > r_sc_w);         // scanout doubling
    .double_h(t_ilace),                          // overlay
```

`video_timing` was correctly given the muxed `v_*` signals; these three reached
past the mux. With a host driving 320x240 the raster ran 320 wide while the test
card was drawn 640 wide -- half the bars filling the screen -- and `hdouble`
compared the table's 640 against the host's 320 and doubled when it should not.

So every mode narrower than the table's own was wrong and every mode the same
width was right, which is why 640x480 always worked and 320x240 never did. It
went unnoticed because the analog output did not work at all until the A/V
board's DAC was driven correctly, and on HDMI the affected modes are not
displayable.

The test card is what found it: fabric-generated, no host, no framebuffer, no
daemon. When it came out wrong the fault had to be in the fabric. It was reached
for several hours later than it should have been.

## The bootloader

Building one from source rather than lifting a binary off a card took three goes
and turned up a bug that had been hiding since M2. The detail is in `UBOOT.md`;
the short version:

- **Mainline u-boot boots but scanout crawls.** Three frames a second, and the
  daemon reporting `brgmodrst 0x00000007` -- all three HPS-to-FPGA bridges still
  in reset. MiSTer's `MiSTer_defconfig` carries the Platform Designer handoff the
  fabric expects; mainline's does not.
- **Our boot command was missing `bridge enable`.** MiSTer's own `fpgaload` has
  it. Ours never did, and it went unnoticed for as long as the hand-off route was
  used, because MiSTer's environment had already issued it. Booting directly meant
  supplying the whole command, and one line was absent. This may be the whole of
  the fault above; the two were not separated.
- **MiSTer's u-boot keeps the boot command in a board header**, not in Kconfig, so
  `make uboot` patches `include/configs/socfpga_de10_nano.h` -- idempotently, and
  keeping the original line beside it.
- **A host with dtc installed collided with u-boot's own libfdt.** Its
  `include/` is deliberately searched after the system directories, so
  `<libfdt.h>` found the host's, and the two use different include guards so
  every fdt type was defined twice. Two search-path fixes failed -- gcc
  deduplicates a repeated `-I` and keeps the later position, and moving
  `include/` to the front breaks `<malloc.h>`. What worked was rewriting the
  includes themselves to paths relative to each file, in 43 places.

The general lesson is the one this project keeps relearning: the answer was in
somebody else's source, and reading it took one fetch where inferring took three
attempts on hardware.
