# blitsCRT_Mister

**A 15kHz analog video card that plugs into USB and makes a CRT an ordinary
monitor.**

It takes the place of a graphics card's analog output, which modern hardware no
longer has, and drives a television or arcade monitor directly -- no emulator in
the middle, no scaler, no line doubler.

![blitsCRT_Mister running on a MiSTer Pi](docs/images/first_light_640x480i.jpg)


## What it does

**Every emulator works unmodified. All of them. Today.**

RetroArch, MAME, DOSBox, PPSSPP, ScummVM, PCSX2 -- and equally a browser, a video
player, or the desktop itself. Not one of them knows the display is unusual,
because it is not: the board enumerates as a **USB graphics device**, the kernel's
own `gud` driver binds to it, and a CRT appears in the display list beside the
real monitors.

No patches. No shims. No `LD_PRELOAD`. Nothing to install on the host -- `gud` has
been in-tree since Linux 5.13, so a current distribution already has everything.

Applications draw to a screen. The pixels come out of a SCART socket at 15 kHz.

That is the point of building it at this layer. MME4CRT, RetroArch's 15 kHz
support and CRTPi -- all of which I wrote -- each needed changes inside the
application, and every new emulator meant the work again. This needs none,
because the CRT support sits below the application entirely.

### What the board does that a graphics card cannot

| | |
|---|---|
| **15.750 kHz line rate** | broadcast timings a television or arcade monitor locks to, which no modern GPU will emit |
| **Any modeline, not a list** | the pixel clock is synthesised on the board per mode. A timing the fabric was never compiled for still works -- 320x224, 256x240, whatever the content wants |
| **Exact clocks** | 0 ppm across the 15 kHz and 31 kHz bands with the fractional PLL. A wrong clock is a slipped frame you can see |
| **Real interlace** | fields interleaved on the read, from a progressive surface the host renders normally |
| **Analog and HDMI together** | the same raster out of both. RGB666 to the CRT, Direct Video out of HDMI |
| **Composite sync for SCART** | `CTRL` bit 3, on by default. A VGA-to-SCART lead does the rest |

### The one thing to arrange

**Resolution.** A CRT wants a modeline matched to the content -- 320x224 for a
Mega Drive game, 256x240 for a NES one, and the right refresh for each. Two ways:

| | |
|---|---|
| **Switchres** | computes a modeline per title from a monitor profile and sets it over GUD. The intended path, and what the fabric is built around: runtime PLL reconfiguration, porches and active size as inputs rather than constants, and a scanout stride padded so any width works |
| **By hand** | `xrandr --newmode` and `--addmode` with a modeline you choose. Fine for a fixed setup, and enough to prove the board before adding anything |

Neither involves the emulator. A mode set either way applies to whatever is on
screen at the time, and one mode is advertised as a fallback so a host with
neither still gets a picture.

### Where it is

Running on hardware: **648x480i60** at a 15.750 kHz line rate from a 12.600 MHz
pixel clock, over USB with LZ4 compression, full-screen at 60 fps.

`make setup && make world` builds everything from source -- bitstream, kernel,
daemon, bootloader -- and writes a card image. Nothing of MiSTer's ends up on it.

GUD is a wire protocol rather than a Linux one, so the same board works
unchanged from Windows: an IddCx driver speaking the same protocol, with
Switchres generating per-game modelines that reach the board with their own
porches. Early, and in its own repository:
https://github.com/alphanu1/gud-windows


## Quick start

```
make setup     # dependencies, a kernel tree, and both cross-compilers
make world     # everything, ending in a card image
```

That is the whole thing. `make world` ends with:

```
  card image:  /path/to/blitsCRT_Mister/blitscrt-0.8.24-d42.img (258M)
               write it with Etcher, Raspberry Pi Imager or dd
```

The image lands in the repository root, named from the version. Write it to a
card and the board boots BlitsCRT on its own -- no serial console, no u-boot
prompt, nothing to import, no MiSTer anywhere on the card.

`make setup` installs the build dependencies through the package manager, offers
to clone a kernel tree, and offers to fetch the cross-compilers. **Two** of those:
a current one for the kernel and daemon, and gcc 5 for MiSTer's u-boot, which is
a 2017 tree and does not survive a modern compiler. `make get-toolchain` fetches
both on their own.

The one thing neither installs is **Quartus**, a manual licensed download.
Without it everything builds except the bitstream -- and therefore the image.

`make world` skips what it cannot build and says what is missing, so a partial
toolchain gives a partial build rather than an error. `make tools` lists what it
detects. If you would rather copy files onto an existing card than write an
image, `make sd DEST=/path/to/mounted/card` does that instead.


## Bringing it up

A card written from `make world`'s image needs nothing. The boot command is
compiled into the bootloader, so the board powers on into BlitsCRT: test card on
the CRT, daemon running, ready for a host.

That matters because u-boot on this board keeps its *saved* environment on the
card rather than in flash -- rewriting a card loses whatever was there, and a
bootloader that already knows what to do does not care. A saved environment still
wins if there is one, so a board someone has deliberately configured keeps its
settings.

### Sharing a card with MiSTer instead

The other way in is to leave MiSTer installed and hand off to it, which is how
this project ran for its first three milestones. Copy the build set onto a MiSTer
card and select `blitscrt.rbf` from the menu:

```
make sd DEST=/path/to/mounted/card
```

MiSTer's own userland reads `blitscrt.txt`, writes the boot configuration to a
magic address and reboots into u-boot, which picks it up. Two full boots on every
power-on and a manual menu selection, but nothing is destroyed and MiSTer is one
power cycle away. `docs/BOOT.md` has the mechanism.

### Changing the boot configuration by hand

`tools/blitsenv.txt` holds a boot environment that can be imported at a u-boot
prompt over serial, for a board that already boots something else or one whose
saved environment needs replacing. `docs/UBOOT_ENV.md` has the procedure and how
to recover from an environment that will not boot.


## Prerequisites

`make setup` handles the software side, including both cross-compilers. What it
cannot do is buy hardware or agree to Intel's licence.

**A MiSTer install is not needed.** The card is built from scratch, bootloader
included, and nothing of MiSTer's ends up on it. A working MiSTer card is still
worth having while developing, since a card that will not boot has no serial
output to interrupt and a MiSTer Pi has no JTAG -- a known-good card is the only
way back.

| | | |
|---|---|---|
| **DE10-Nano or MiSTer Pi** | required | the board itself |
| **I/O Analog Pro** | required | the ADV7125 board. The only 15 kHz RGB output, and the one this was brought up against -- see below |
| **microSD card** | required | dedicated to BlitsCRT, since it replaces the boot chain on it |
| **USB cable, VBUS cut** | required | host link. Which cable depends on where it goes -- see **USB** |
| **Serial console** | advisable | the HPS UART at 115200 is where the boot log and the daemon appear. Not needed to install, only to debug |
| **Quartus Prime Lite** | for the bitstream | free but licensed, and a manual download |
| **USB hub board** | optional | may stay fitted. Its upstream micro-B is the host link |

### Which A/V board

**I/O Analog Pro** is the required board. There are two and they are not
interchangeable, and this was brought up against the Pro -- the older one is
supported but untested here.

**The older analog I/O board** takes RGB666 straight off the FPGA pins into a
passive resistor ladder. No ICs on the video path.

**I/O Analog Pro** carries an Analog Devices ADV7125 video DAC, plainly visible
as a 48-pin QFP. A DAC latches nothing without a clock, so it needs three signals
the older board did not, and MiSTer puts them on the pins the older board used
for status LEDs:

| pin | ball | older board | I/O Analog Pro |
|---|---|---|---|
| `LED_USER` | Y15 | user LED | `VCLK`, the DAC's latch clock |
| `LED_POWER` | AG28 | power LED | `BLANK*`, driven by data enable |
| `LED_HDD` | AA15 | disk LED | `SYNC*`, composite sync |

Balls come from MiSTer's `sys/sys_analog.tcl`, which is the authority -- forum
posts differ and at least one has them wrong.

`CTRL` bit 7 selects, and is **on by default** because that is the board this was
brought up against. On the older board clear it, or the LEDs stay dark and the
ladder receives a pixel clock:

```
blitscrt-peek -w 0x08 <ctrl & ~0x80>
```

Colour is 6-bit rather than 8. The DAC's low two bits per channel travel on the
secondary SD card pins, which this fabric does not drive.

### USB

The host link is driven by the HPS `dwc2` controller in peripheral mode. There
are two places to plug it in, and both work.

**With the hub board fitted.** The cable goes into the hub board's upstream
micro-B. That connector is wired in parallel with the hub's 4-pin `USB IN`
header -- same D+, D-, VBUS and GND -- so it reaches `dwc2` through the bridge,
and the hub board stays bolted on with every port still facing out. This is the
route to prefer: nothing comes apart, and a normal MiSTer stack becomes a
BlitsCRT one by moving a cable.

**With the hub board removed.** The cable goes into the board's own OTG port. On
a DE10-Nano that is the micro-AB connector; a MiSTer Pi fits a **Type-A**
receptacle instead, so the cable is A-to-A there.

**The cable must have VBUS cut, whichever route.** Both ends of the link
look like hosts and only one may supply power. Into the hub's micro-B it matters
twice over: the hub's VBUS is common with the header's, so a stock cable powers
the hub controller directly -- which then presents its own pull-up and wins the
enumeration -- and backfeeds 5 V into the board's OTG VBUS at the same time. A
stock cable there reproduces the original failure exactly. Lift pin 1 in the plug
shell, or use a data-only lead.

The hub does **not** have to come off. An earlier revision of this document said
it did, on the strength of a host enumerating a 7-port hub instead of the gadget.
That was observed while `/sys/class/udc/` was still empty -- there was no gadget
for the host to find, and the board was sourcing VBUS because `dwc2` had come up
as host. One pull-up unopposed, not two in contention. With the gadget registered
and VBUS cut, the hub controller is unpowered and silent, and the host finds the
display.


## Build

`make world` is the whole thing. Individually:

| | |
|---|---|
| `make uboot` | u-boot and the preloader, with our environment compiled in |
| `make image` | a complete SD card image, ready for `dd` |
| `make world` | all of the below, ending in a card image |
| `make setup` | dependencies, kernel tree, both cross-compilers |
| `make get-toolchain` | the two cross-compilers on their own |
| `make bitstream` | the `.rbf`, via Quartus |
| `make linux` | zImage, device tree and initramfs |
| `make daemon` | `blitscrtd`, cross-compiled |
| `make peek` | `blitscrt-peek`, the register tool |
| `make build` | stage everything into `build/` |
| `make sd DEST=...` | copy that onto a mounted card |
| `make sim` | RTL testbenches under Icarus |
| `make -C sw test` | daemon unit tests |
| `make lint` | elaborate the top level, catching what a testbench would not |
| `make check-pins` | diff pin assignments against MiSTer's |

`make sim` and `make -C sw test` need no hardware and no Quartus. They are the
fast check that nothing has broken.

### Versions

Four numbers, each answering a different question. `VERSION` holds the first, so a
release workflow can read it without parsing a Makefile.

```
make -s versions

version=0.8.10                            the project, from VERSION
daemon=d42                                blitscrtd
kernel=k12                                anything baked into the zImage
full=0.8.10-d42                           what brands the kernel
fabric=3.22                               the VERSION register in the RTL
localversion=-BlitsCRT-0.8.10-d42-k12     what uname -r carries
```

The daemon build is appended to the project version because the daemon is
embedded in the initramfs: a daemon change rebuilds the kernel image, so an image
that says `0.8.10-d42` really does carry d42. `make -s version` and
`make -s fullversion` print the first two alone, for a CI job to capture.

The daemon also carries its tag inside the binary, because "the fix did not work"
and "the fix never reached the board" look identical from the far end of a serial
cable:

```
grep -a -o 'blitscrtd-build=[a-z0-9]*' /media/fat/blitscrt/blitscrtd
```


### Building a card image

`make world` does this as its last step, and `make image` on its own repeats it.
The output is `blitscrt-<version>.img` in the repository root -- write it with
Etcher, Raspberry Pi Imager or `dd`. No root is needed to build it: the FAT
filesystem is written with mtools rather than by loop-mounting, so it runs in CI
unchanged, and nothing in the build ever touches a block device.

The card ends up as:

| | |
|---|---|
| partition 1 | FAT32 -- bitstream, kernel, daemon |
| partition 2 | type `a2` -- the preloader and u-boot, as raw sectors |

FAT is numbered first because `bootcmd` addresses it as `mmc 0:1`. The A2
partition still sits first on disk -- table order and disk order are independent,
and Cyclone V's BootROM scans for the partition *type* rather than the number.

Everything on it is built here, including the bootloader. `make uboot` produces
that, and `docs/UBOOT.md` covers what it takes -- MiSTer's u-boot needs an old
compiler, and three patches to build against a modern host at all.


### Releasing

Pushing a commit that changes `VERSION` builds and publishes a GitHub release:
image, build set, and a changelog assembled from the commit subjects since the
previous tag. Nothing else triggers it, so ordinary commits cost nothing.

**CI does not build the card.** It cannot: Quartus is a ~10 GB licensed install,
and the kernel and u-boot each need their own cross-compiler -- u-boot's being
gcc 5, eight major versions behind everything else.

So **`build/` is committed**. It is the whole card: bitstream, kernel, device
tree, daemon, tools and the bootloader. `make world` stages all of it, including
the bootloader -- `make stage-uboot` does that part alone, and finds an existing
`.sfp` without rebuilding u-boot.

```
make world
git add -A build
echo 0.8.22 > VERSION
git commit -am "release 0.8.22" && git push
```

CI then checks every file is present, runs the tests that need no toolchain,
wraps `build/` into an image and publishes it. It refuses to release if anything
is missing, and warns if the bitstream is older than the RTL.

That also makes any tag rebuildable into the exact card it shipped, which a
release built from sources at head would not be.


## Documentation

| | |
|---|---|
| `docs/ROADMAP.md` | the milestones in detail, and what each one cost |
| `docs/DESIGN.md` | how it works: mode selection, the write path, the PLL solver |
| `docs/BRINGUP.md` | step by step to first picture |
| `docs/INTERLACE.md` | interlace at 60 Hz, and the two monitor profiles |
| `docs/VBLANK.md` | why gud has no vblank, and what adding one takes |
| `docs/UBOOT.md` | the bootloader: why MiSTer's, what gets patched, and why |
| `docs/UBOOT_ENV.md` | the boot environment: importing, changing, recovery |
| `docs/BOOT.md` | how the bitstream reaches the FPGA |
| `docs/MEGAFUNCTIONS.md` | the PLLs: integer against fractional, and how to switch |
| `docs/GP_FINDINGS.md` | the HPS-to-fabric transport, measured on hardware |
| `docs/DIRECTION.md` | what the project is for and what it is not |


## What the daemon advertises

**One mode: 648x480i60**, flagged `PREFERRED`.

| mode | pixel clock | line | field | timing |
|---|---|---|---|---|
| **648x480i60** | 12.600 MHz | 15.750 kHz | 60.00 Hz | 648 670 730 800 / 480 486 492 525 |

Not 640, on purpose. Switchres generates 640-wide timings, and a host offered both
would have two modes that look interchangeable and are not: this one is a fixed
fallback, its are computed for the monitor. A few pixels is invisible on a CRT and
makes the two impossible to confuse in a log.

**This is a fallback, not a limit.** A host can set a timing that was never in the
list, which is the Switchres case and the intended one. The list exists so a host
without Switchres still gets a picture.

### Interlace

An interlaced mode is passed through as it arrives, and the fabric interleaves on
the read -- `video_timing.v` turns a 480-line surface into two 240-line fields.
Whether that runs at 60 Hz motion depends on the host: some kernels rate an
interlaced mode at its field rate and render 60 frames a second, others rate it at
the frame rate and render 30. Measured on the same daemon: 60 on a laptop with an
Intel iGPU, 30 on a desktop with a Radeon RX 9070 XT. Not the compositor -- that
machine halves it with KWin on and off. `docs/INTERLACE.md` has what is and is
not ruled out.

Where it halves, the daemon offers a way round: a **31 kHz progressive** mode is
rewritten into a 15 kHz interlaced one on arrival, so the host is never told the
display is interlaced and renders at the full rate. The conversion fires only for
progressive modes out of the 15 kHz band whose half is inside it, so an interlaced
mode is never touched and a 240p mode is never touched.

Which route is used is decided by the monitor profile, not by any setting here.
`docs/INTERLACE.md` has both, the `crt_range` lines for each, and why the 31 kHz
range must carry half the porch times of the 15 kHz one.

The scanout stride is padded to a whole 8-byte f2sdram beat, so **any** width
works. The port is 64 bits and Avalon reads are word-addressed, so line *n* at
`base + n * stride` only lands on a beat boundary if the stride is a multiple of
eight; 642 pixels at 16bpp is 1284 bytes, or 160.5 beats, and sheared until the
padding went in. Proven on hardware by advertising 642 and 648 together -- one
needs padding, one does not, both stable.


## The fabric's own modes

Shown when no host is attached:

| mode | pixel clock | line | field |
|---|---|---|---|
| 640x480i60 | 12.600 MHz | 15.750 kHz | 60.00 Hz |

One, so there is nothing to select and the front-panel buttons are free for other
things. There were three: 640x480p60 at 31.5 kHz went first, a diagnostic for a
monitor that will not take 15 kHz, which this is not for; 640x240p60 went with the
button that cycled to it.

The timing generator has no built-in modes of its own. Porches, active size and
the interlace flag are all inputs, latched while the pipeline is held in reset. It
drives whatever timing it is given; only the clock is pinned.


## The front panel

Three buttons and three LEDs, left to right on the I/O board.

| button | |
|---|---|
| **RESET** | resets the board |
| **OSD** | shows and hides the on-screen text |
| **USER** | disconnects the display from the host, and reconnects it. One press each way |

| LED | |
|---|---|
| **POWER** | solid whenever the PLL is locked, which is whenever video is being generated at all |
| **DISK** (orange) | the display is *not* available: the user button has disconnected it, or the daemon has not come up yet |
| **USER** (green) | the display is available to a host |

DISK and USER are complementary, which is what having two colours is worth: green
means the display is there, orange means it has been taken away. Exactly one is
lit once the board is running, so a dark pair is itself a fault -- and orange at
power-on turning green is the daemon starting.

The OSD button inverts whatever the daemon wants rather than only hiding. So with
no host it hides the text over the test card, and **with a host driving it brings
the text up over the desktop** -- which is the useful direction, since the overlay
reads its numbers back from `LIVE_*` and reports what the raster is really running
rather than what the host asked for:

```
MODE   648X480I 60.00HZ
LINE   15.750 KHZ
PIXEL  12.600 MHZ
TIMING HOST
```

### Why the user button exists

Pulling the cable leaves the last frame frozen on screen. The revert to the test
card is driven by `FUNCTIONFS_DISABLE`, and dwc2 raises that from VBUS going
away -- which the cable, with VBUS cut on the board side, never sees. Worse
than cosmetic: on X11 a host can panic when a live output disappears underneath
it.

Unbinding the UDC does raise the event, so the whole detach path runs the way it
does for a host-initiated disconnect. The test card comes back and the host sees
an output go away in order.

It stays disconnected until pressed again, so the cable can stay plugged in while
the display is taken away -- long enough to reboot the machine, reconfigure a
desktop, or unplug at leisure.

### Where they actually are

On a board fitted with I/O Analog Pro, none of these are on the pins their
names suggest. The `LED_*` pins carry the DAC's clock, blank and sync, and the
`BTN_*` pins carry nothing. All six are behind an **MCP23009 I2C expander**, on a
bus bit-banged in the fabric -- `IO_SCL` on `PIN_U14` and `IO_SDA` on `PIN_AG9`,
from MiSTer's `sys/sys.tcl` under a heading that reads "I2C LEDS/BUTTONS". Note
that `sys_analog.tcl` has no trace of it, despite being where the LED and button
pins themselves live.

`rtl/mcp23009.v` drives it. When the expander answers, its buttons are used; when
it does not, the `BTN_*` pads are, which is right for a DE10-Nano with the older
I/O board. `blitscrt-peek -i` reports which source is in use and what each button
is doing.

Two things about the expander that are easy to get wrong, and were:

- **Its outputs are open drain.** Writing 0 pulls a pin to ground and lights its
  LED; writing 1 releases it. An active-high signal inverts on the way out.
  Backwards, every LED lights at exactly the wrong moment, which reads as three
  separate faults rather than one.
- **It reports `{GP5, GP4, GP3}` = `{OSD, reset, user}`**, so bit 0 is user and
  bit 2 is OSD. Swap those and each button does another's job -- visible
  immediately, and the first thing to check if one misbehaves.


## Reading what it is doing

The daemon prints a line a second, unconditionally:

```
blitscrtd: 648x480i host timing -- 60.0 fps -- wait 1.7 ms, xfer 0.0 ms,
           lz4 0.7 ms, blit 5.6 ms, critical path 6.3 of 16.7 available
```

`critical path` against `available` is the question worth asking. The device uses
about 9 ms of a 16.7 ms budget, so if `available` is much larger the frames are
simply not arriving and the cause is upstream -- a flaky USB hub produced exactly
that. `wait` is time before the first byte lands; `xfer 0.0` means the frame was
already buffered when the read was issued.

The mode is on the line because there is no other way to see it while running:
`blitscrt-peek` needs the daemon stopped, and stopping it clears `HPS_TIMING`, so
a peek always reports the front-panel table whatever was on screen.

`blitscrt-peek` reads the fabric directly. `-t` for the live raster, `-g` for
scanout geometry and underruns, `-i` for the I/O board pins.


## Status

| | |
|---|---|
| **M1** fabric only | done -- 15kHz out of the analog board and HDMI |
| **M2** custom kernel and runtime control | done -- own kernel, own init, registers over gp |
| **M3** scanout memory | done -- HPS DDR3 over f2sdram, custom pixel clocks by PLL reconfiguration |
| **M4** GUD USB host link | done -- a host enumerates it as a display and drives it |
| **M5** bandwidth | done -- LZ4, 60 fps full-screen |
| **M6** front panel and soft disconnect | done -- buttons and LEDs through the I2C expander, and a button that disconnects the display without touching the cable |
| **M7** Windows host | working, early -- an IddCx driver speaking the same GUD protocol, with a Switchres backend. Its own repository: https://github.com/alphanu1/gud-windows |
| **M8** vblank in gud | not started -- the driver reports none, so a host's vsync has nothing to synchronise to and renders whenever it likes. `docs/VBLANK.md` |

`docs/ROADMAP.md` has each milestone in full: what it covers, what is done, and
what it cost to get working.


## Known limitations

- **Unplugging the cable still leaves the last frame frozen.** The user button is
  the way to disconnect cleanly; pulling the cable is not detectable, because the
  cable has VBUS cut and that is what dwc2 raises `FUNCTIONFS_DISABLE`
  from. `/sys/class/udc/<name>/state` reports `configured` independently of the
  FunctionFS event stream, so polling it would catch an unannounced unplug too.
- **No vblank.** `gud` reports none, so an application's vsync has nothing to
  synchronise to and the host renders whenever it likes -- measured at 186
  frames a second against a 59.99 Hz raster. Frames land in memory mid-scan, so
  the picture can tear, and most of what the host draws is overwritten before it
  is shown. `docs/VBLANK.md`; it is **M8**.

- **A host framebuffer larger than the mode is cropped, not scaled.** An X screen
  that has not followed a mode switch sends rects wider than the raster; the blit
  clips them to the left edge and the daemon says so once. The fix is on the host
  -- Switchres has `screen_compositing` and `screen_reordering` for it.

- **RGB888 is not offered.** `scanout_fetch.v` needs a two-beat read window for a
  3-byte pixel that straddles a beat. RGB565 is the only format advertised. This
  is about what the host sends, not about output depth -- see below.
- **Colour is 6-bit, not 8**, and getting to 8 takes three things rather than one.
  The pipeline is RGB666 end to end, written for the older board's resistor
  ladder: `scanout.v` truncates an 8-bit source to six on the way in, and only
  `VGA_R/G/B[5:0]` are driven. So it needs an RGB888 source format (above), the
  pipeline widened, and the DAC's low two bits per channel driven -- those are on
  the secondary SD card pins, `SDIO_DAT[3:0]`, `SDIO_CMD` and `SDIO_CLK`, which
  MiSTer sends as `{vga_g,vga_r,vga_b}`. Any one alone changes nothing visible.
- **No EDID is sent**, so the connector reads `VGA-1-unknown`. One is implemented
  in `sw/edid.c` and disabled: sending it breaks mode selection, with a bare name
  descriptor as much as with range limits. Both lack a timing descriptor, which is
  the likely cause. `BLITSCRT_EDID=name` or `=full` for anyone investigating.
- **The link carries about 35 MB/s**, which bounds what a Switchres modeline can
  ask for. 1280x480i60 is 73.7 MB/s of RGB565 and does not fit even at 2.58x
  compression; 1280x240p60 is half that and works.
- **HDMI hot plug detect is inferred** from the transmitter acking I2C, since
  `rtl/i2c_master.v` cannot read its HPD register. No symptom: the inference only
  feeds boot-time mode selection when no analog board is fitted, and the analog
  board is required.


## Credits and licensing

**GPL-2.0-or-later**, full text in `LICENSE`. The project began MIT and moved when
it took MiSTer's `sysmem_lite` for the f2sdram path: GPL code cannot go into an MIT
work and leave it MIT. Every source file carries an SPDX line.

One file stays MIT and has to. `sw/gud.h` carries Noralf Trønnes' copyright and the
MIT permission notice, which MIT requires be retained. A GPL work may contain
MIT-licensed files provided each carries its own notice, so that header travels
with the code it covers.

Four things came from elsewhere and I want them named.

**Pin assignments** in `quartus/pins.tcl` come from MiSTer's `sys/sys.tcl` and
`sys/sys_analog.tcl`. They describe how the board is wired. `make check-pins` diffs
mine against theirs.

**`sysmem_lite`** in `rtl/mister/sysmem.sv`, with `f2sdram_safe_terminator.sv`
(Copyright 2021 bellwood420), come from the same tree and are **GPL-2.0**. Theirs
is used rather than a system generated here because the f2sdram port configuration
is latched by `APPLYCFG` while the SDRAM interface is idle -- the preloader's job,
and something Linux cannot do at all.

**The GUD protocol** is Noralf Trønnes' work, MIT licensed. `sw/gud.h` mirrors the
part of `include/drm/gud.h` the device side needs. The host driver has been in-tree
since Linux 5.13. GUD lost its maintainer in January 2025 and the upstream repo is
archived, but the protocol is frozen and the driver still works.

**The ADV7513 register table** in `rtl/adv7513_init.v` follows the sequence in
`Main_MiSTer/video.cpp`, which is GPL-2.0. Somebody else debugged that order and I
took it. Two values are mine: `0x3B = 0x00` for automatic pixel repetition, and
`0xAF = 0x04` for DVI instead of HDMI.

All four are GPL-2 and so is this, so they are borrowed on the terms they were
offered under. Each carries a notice naming where it came from, in the file rather
than only here.
