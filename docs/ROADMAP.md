# Roadmap and status

The milestone history, in detail: what each one covers, what is done, and what
was learned getting there. The README carries the summary.

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
| done | BlitsCRT-0.10 kernel boots, mounts the card, writes the boot log |
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
| done | all four advertised modes reachable; three of them need reconfiguration |

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
| done | the four advertised modes all solve and all apply; `modelist_add` refuses anything `mode_check` would reject |
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
| note | composite sync is implemented and switchable at runtime on `CTRL` bit 3, but has not been tried on a set that needs it |
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

*The bulk endpoint does not write pixels.* `gadget.c` drains the transfer and counts
it so the host stays happy, and the rect never reaches memory. So a host will
enumerate, modeset correctly, negotiate a format and stream frames, and the screen
will not change. Small now rather than large: `blitscrt_scanout_blit()` takes
exactly the x/y/w/h a GUD `set_buffer` request carries, and routes itself.

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
| done | 640x480i60 full-screen runs at 51.98 fps uncompressed, 31.9 MB/s -- bandwidth-limited |
| done | measured on real traffic: 2.58x on a desktop, 253x on a static screen. LZ4 reaches 60 fps |
| done | LZ4 stable: read requests rounded to a packet boundary, so a transfer neither splits nor swallows the frames behind it |
| done | the read overlaps the decompress and blit: two threads and a two-slot pool, so a frame costs `max(read, lz4 + blit)` |
| done | decompression costs the ARM 2.1 ms on a quiet frame, 4.3 on a busy one -- a less compressible frame is both more to carry and more to expand |
| done | measured on real traffic: 2.58x sustained, 253x on a static screen, and the daemon reports achieved fps against the frame budget |
| **todo** | **a two-beat read window in `scanout_fetch.v`, so RGB888 works: the only format that uses the whole ladder, and the only deep one that fits 640-wide with LZ4** |

Measured on hardware. Raw, RetroArch full-screen at 640x480i60 runs **51.98 fps**
-- 614400 bytes a frame at 31.9 MB/s, bandwidth-limited against the ceiling below.
With LZ4 the same content reached **60.01 fps**, the vsync cap, at 2.58x: 239 KB a
frame, about 14 MB/s, well inside budget.

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

**M6 -- Switchres modes at boot. Not started.** Four modes are advertised today,
hardcoded in `blitscrt_modelist_defaults()`, and they are the wrong four for most
people. A Sony PVM, a Hantarex arcade chassis and a PAL television have different
sync bands, and the list a host should see differs accordingly.

So: at boot, read a monitor profile, run Switchres against it, and build a curated
list of selectable resolutions from what it returns. The hardcoded four become the
fallback for when there is no ini, not the answer.

*It has to happen at startup, before a host attaches.* GUD asks for the mode list
once, in `GET_CONNECTOR_MODES` during enumeration, and takes what it is given.
There is no mechanism to grow the list afterwards short of forcing a re-enumerate.
So generation runs when the daemon starts, the list is complete before the gadget
binds its UDC, and the first host to connect sees the finished thing.

This is the same job CRTPi does on the Pi, and the configuration should read the
same on both -- one person operating both boards should not have to learn two
vocabularies:

```
monitor_profile = arcade_15 | arcade_15_25_31 | ntsc | pal
                | crt_range:<hfmin>-<hfmax>,<vfmin>-<vfmax>
gud_heights     = 224,240,256,288,448i,480i,576i
gud_refreshes   = 50,55,57,60
gud_superres    = on
profile_enforce = on
```

The profile does three jobs. It seeds the generated list, expanding height classes
against refresh targets and keeping only what lands inside the band. It clamps
whatever a host asks for afterwards, including the unadvertised modelines
Switchres sends on the host side. And if mode-on-demand ever arrives, it is what
the synthesizer works against.

Overriding stays possible at every level: an extra-modes file appended to the
generated list for the one mode a particular chassis wants, and unadvertised
modelines still accepted at runtime exactly as they are now.

| | |
|---|---|
| todo | read `blitscrt.ini` from the FAT partition, so it can be edited on any PC |
| todo | the standard profiles as `blitscrt_sink_limits` instances, plus `crt_range:` for anything exotic |
| todo | generate at daemon start: height classes x refresh targets, each solved through `pll.c` and kept only if it lands inside the band |
| todo | fall back to the hardcoded four when there is no ini, so a card with no configuration still works |
| todo | super-resolution variants, 2560 wide, so the host GPU does the horizontal scaling -- invisible on a CRT and cheap on the host |
| todo | an extra-modes file appended to the generated list |
| todo | `profile_enforce` wired to `mode_check`, refusing out-of-band timing rather than passing it to the deflection circuit |
| note | the clamp is a safety feature, not a convenience. Fixed-frequency deflection can be damaged by sync outside its band, so it defaults on |

*Much of this is already here in embryo.* `blitscrt_sink_limits` is a monitor
profile with one hardcoded instance. `mode_check` is `profile_enforce` already
written, and `BLITSCRT_MAX_MODES` already bounds the list. `pll.c` solves a
modeline to a PLL configuration and reports the error in ppm, which is exactly the
"can this monitor reach it" test a generator needs. `blitscrt_mode_from_modeline`
takes Switchres-style modelines, so an extra-modes file needs no new parser. What
is missing is reading the ini, the profiles themselves, and the expansion.

*Whether to link libswitchres.* CRTPi does, on the device. The same would work
here. But `pll.c` already produces what a modeline needs and the profiles are a
dozen numbers, so generating directly from the profile may be enough -- worth
deciding once the ini and the profiles exist, rather than committing to a
dependency first.

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
