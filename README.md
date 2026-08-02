# blitsCRT_Mister

A 15kHz analog video card that enumerates over USB as a display.

Plug it into a PC and a CRT appears as an ordinary monitor -- listed alongside
the real ones, selectable, resizable, with nothing to install on the host. The
desktop renders on it. Emulators run full-screen at 60 fps. Underneath, the pixel
clock is synthesised on the board for whatever mode is asked for, so a timing the
fabric was never compiled for still works.

Running on hardware today: 648x480i60 at a 15.750 kHz line rate from a 12.600 MHz
pixel clock, over USB with LZ4 compression, full-screen at 60 fps.

`make setup && make world` builds everything from source and writes a card image.
Nothing of MiSTer's ends up on the card.

Both outputs carry the same pixel stream. Analog RGB666 goes out of the A/V
board's VGA connector for a CRT, and the same raster goes out of HDMI as Direct
Video. For SCART, `CTRL` bit 3 selects composite sync on the HS pin -- on by
default -- and a VGA-to-SCART lead does the rest.

The host side is the in-tree Linux `gud` driver, nothing bespoke. GUD is a wire
protocol rather than a Linux one, so a Windows driver would work against the same
board unchanged; that is **M7**.

![blitsCRT_Mister running on a MiSTer Pi](docs/images/first_light_640x480i.jpg)


## What it is for

A CRT that any operating system can drive, without an emulator in the middle and
without a scaler. The board takes the place of a graphics card's analog output,
which modern hardware no longer has, and generates broadcast-rate timings a
television or arcade monitor will actually lock to.

One advertised mode exists as a fallback. The intended use is **Switchres**,
which computes a modeline for the monitor in front of it and sets it through the
GUD protocol -- a timing that was never in any list. Everything the fabric does is
built around that: the PLL is reconfigured at runtime, porches and active size are
inputs rather than constants, and the scanout stride is padded so any width works.

Before this I wrote MME4CRT, RetroArch's 15kHz support, and CRTPi. This is the
same problem approached from the hardware end.


## Quick start

```
make setup     # dependencies, a kernel tree, and both cross-compilers
make world     # everything, ending in a card image
```

That is the whole thing. `make world` ends with:

```
  card image:  /path/to/blitsCRT_Mister/blitscrt-0.8.12-d42.img (258M)
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

`make setup` handles the toolchain. What it cannot do is buy hardware or agree to
Intel's licence.

| | | |
|---|---|---|
| **DE10-Nano or MiSTer Pi** | required | the board itself |
| **Analog A/V board** | required | the only 15 kHz RGB output. Which board matters -- see below |
| **microSD card** | required | dedicated to BlitsCRT, since it replaces the boot chain on it |
| **A-to-A USB cable, VBUS cut** | required | host link, into the board's Type-A OTG port |
| **Serial console** | advisable | the HPS UART at 115200 is where the boot log and the daemon appear |
| **Quartus Prime Lite** | for the bitstream | free but licensed, and a manual download |
| **USB hub board** | must be removed | the gadget does not work with it fitted |

### Which A/V board

There are two and they are not interchangeable.

**The older analog I/O board** takes RGB666 straight off the FPGA pins into a
passive resistor ladder. No ICs on the video path.

**The newer A/V board** carries an Analog Devices ADV7125 video DAC, plainly
visible as a 48-pin QFP. A DAC latches nothing without a clock, so it needs three
signals the older board did not, and MiSTer puts them on the pins the older board
used for status LEDs:

| pin | ball | older board | newer board |
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

The host link goes into the board's USB OTG port, driven by the HPS `dwc2`
controller in peripheral mode. On a DE10-Nano that is the micro-AB connector; a
MiSTer Pi fits a **Type-A** receptacle instead, so the cable is A-to-A with VBUS
cut on the board side -- both ends look like hosts and only one may supply power.

The micro-USB on an assembled MiSTer Pi belongs to the hub add-on, not the OTG
port. A PC plugged into it enumerates a 7-port hub and nothing else. The hub must
come off entirely: it and the gadget share the same controller.


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
| partition 2 | type `a2` -- the preloader and u-boot, raw sectors |

FAT is numbered first because `bootcmd` addresses it as `mmc 0:1`, the same as a
MiSTer card. The A2 partition still sits first on disk; table order and disk
order are independent, and Cyclone V's BootROM scans for the partition *type*
rather than the number.

That A2 partition is the part that cannot be generated from nothing -- it is not
a file and not in any filesystem, so formatting a card destroys it and the board
will not boot at all: no serial output to interrupt and, on a MiSTer Pi, no JTAG
to recover through. `make uboot` builds one; `docs/UBOOT.md` covers how, and it
is more involved than it sounds.

**Or lift one from a MiSTer card**, which needs no bootloader build at all:

```
tools/make_image.sh --extract-boot /dev/sdX boot.a2
make image BOOT_A2=boot.a2
```

That takes everything from sector 1 up to the first filesystem, not just the A2
partition, and writes it back at the same absolute sectors -- so if the boot
environment lives at a raw offset on the card rather than in flash, it comes
along. The blob is MiSTer's u-boot, GPL-2.0, so it can be passed on under the
same terms with an offer of source, but it is not this project's code to
relicense.

`make image` prints which bootloader it used. Worth reading that line before
writing a card, since `UBOOT_DIR` applies only to the command it is given to.


### Releasing

Pushing a commit that changes `VERSION` builds and publishes a GitHub release:
image, build set, and a changelog assembled from the commit subjects since the
previous tag. Nothing else triggers it, so ordinary commits cost nothing.

CI does not run Quartus -- it is a ~10 GB licensed install and a hosted runner
has no state between runs. The bitstream is built locally and committed, which
is also what makes any tag rebuildable into the exact image it shipped:

```
make bitstream
cp quartus/output_files/blitscrt.rbf release/blitscrt.rbf
git add release/blitscrt.rbf
echo 0.8.13 > VERSION
git commit -am "release 0.8.13" && git push
```

The workflow refuses to publish without that `.rbf`, and warns if anything in
`rtl/` is newer than it. `.github/workflows/release.yml` has the detail.


## Documentation

| | |
|---|---|
| `docs/ROADMAP.md` | the milestones in detail, and what each one cost |
| `docs/DESIGN.md` | how it works: mode selection, the write path, the PLL solver |
| `docs/BRINGUP.md` | step by step to first picture |
| `docs/UBOOT.md` | the bootloader: why MiSTer's, what gets patched, and why |
| `docs/UBOOT_ENV.md` | the boot environment: importing, changing, recovery |
| `docs/BOOT.md` | how the bitstream reaches the FPGA |
| `docs/MEGAFUNCTIONS.md` | regenerating the PLL and its reconfiguration block |
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
away -- which the A-to-A cable, with VBUS cut on the board side, never sees. Worse
than cosmetic: on X11 a host can panic when a live output disappears underneath
it.

Unbinding the UDC does raise the event, so the whole detach path runs the way it
does for a host-initiated disconnect. The test card comes back and the host sees
an output go away in order.

It stays disconnected until pressed again, so the cable can stay plugged in while
the display is taken away -- long enough to reboot the machine, reconfigure a
desktop, or unplug at leisure.

### Where they actually are

On a board fitted with the newer A/V board, none of these are on the pins their
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
| **M7** Windows host | not started, and its own repository |

`docs/ROADMAP.md` has each milestone in full: what it covers, what is done, and
what it cost to get working.


## Known limitations

- **Unplugging the cable still leaves the last frame frozen.** The user button is
  the way to disconnect cleanly; pulling the cable is not detectable, because the
  A-to-A cable has VBUS cut and that is what dwc2 raises `FUNCTIONFS_DISABLE`
  from. `/sys/class/udc/<name>/state` reports `configured` independently of the
  FunctionFS event stream, so polling it would catch an unannounced unplug too.
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
