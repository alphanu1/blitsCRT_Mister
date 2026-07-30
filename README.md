# blitsCRT_Mister

A 15kHz analog video card that enumerates over USB as a display.

Plug it into a PC and a CRT appears as an ordinary monitor -- listed alongside
the real ones, selectable, resizable, with nothing to install on the host. The
desktop renders on it. Emulators run full-screen at 60 fps. Underneath, the pixel
clock is synthesised on the board for whatever mode is asked for, so a timing the
fabric was never compiled for still works.

Running on hardware today: 640x480i60 at a 15.750 kHz line rate from a 12.600 MHz
pixel clock, over USB with LZ4 compression, full-screen at 60 fps.

Both outputs carry the same pixel stream. Analog RGB666 goes out of the A/V
board's VGA connector for a CRT, and the same raster goes out of HDMI as Direct
Video. For SCART, set the `CSYNC` parameter or `CTRL` bit 3, and use a
VGA-to-SCART lead.

The host side is the in-tree Linux `gud` driver -- nothing bespoke. GUD is a wire
protocol rather than a Linux one, so a Windows driver would work against the same
board unchanged; that is **M7**.

**Status** below, and `docs/ROADMAP.md` for the detail.

## Quick start

```
make setup                            # toolchain: cross-compiler, iverilog, dtc, git
make world                            # build everything the installed tools allow
make sd DEST=/path/to/mounted/card    # copy it all to the card
```

Then set the u-boot environment once, so the board boots this rather than MiSTer
-- `docs/UBOOT_ENV.md`. After that it comes up on its own: 15 kHz out of the A/V
board, and a display a host PC can use over USB.

`make setup` is the first step: it installs the build dependencies through the
package manager and offers to clone a kernel tree. It does not install Quartus,
which is a manual licensed download — see **Prerequisites**. `make world` then
builds whatever it finds a toolchain for and skips the rest with a note naming
what is missing, so a partial toolchain still yields a partial build rather
than an error. **Prerequisites** and **Build** have the detail.

## Lineage

This grew out of **BlitCRT** — <https://github.com/alphanu1/blitcrt> — my 15kHz
FPGA video card. It is a blit streamer: the host pushes damage rectangles
straight into live scanout over FT245. No present, no flip, nothing to double
buffer.

Before that I wrote MME4CRT, RetroArch's 15kHz support, and CRTPi.

**This is a blit streamer too.** The model is defined by the write path, not by
where the pixels live. BlitCRT keeps a 4bpp frame on-chip in block RAM and is
still a streamer, because rects go into live scanout and nothing is ever
presented or flipped. Same here.

GUD suits that. It is a damage-rect protocol: a cursor crossing a static screen
costs a few hundred bytes instead of a megabyte, and there is no frame
submission step anywhere in it.

What changes is how much scanout memory the write path needs, and this board has
far more of it than the Cyclone IV BlitCRT runs on. See **Scanout memory** below
for where the pixels go. M3 is the plumbing, not a change of model.

Target is the MiSTer Pi (Cyclone V SE 5CSEBA6U23I7) with the analog A/V board.
A DE10-Nano works identically.

![blitsCRT_Mister running on a MiSTer Pi, 640x480i60 over HDMI](docs/images/first_light_640x480i.jpg)

*Work in progress. The fabric running on a MiSTer Pi, mode 1 at 640x480i60,
out of HDMI as Direct Video. The overlay is reading its own timing back: 15.750
kHz line rate, 12.600 MHz pixel clock, and the porch numbers the timing
generator was handed.*

*This shot predates the current banner text, which spells out that the vertical
values are per field and gives the totals. The photograph is otherwise what the
hardware does.*

![blitsCRT_Mister runtime, work in progress](docs/images/runtime_m1.gif)

*The same thing moving.*

[Full clip, 640x480i60 out of HDMI](docs/video/runtime_m1.mp4)

Below is the same design rendered from simulation, one pixel at a time straight
out of the datapath:

![blitsCRT_Mister test card, 640x240p60](sim/testcard_640x240p60_x2.png)

## The goal

A blit streamer that a host treats as an ordinary display, driving a 15kHz CRT
with no emulator in the path.

The device implements GUD (Generic USB Display). On any Linux machine it
enumerates as a `drm_device` — a real `/dev/dri/card*`. Nothing on the host knows
or cares that the panel is a CRT hung off an FPGA. Drag a window onto it, run a
native arcade port, or point Wayland at it, and the pixels come out at 15kHz. That
is the whole point: the CRT stops being tied to an emulator pipeline and becomes a
display the OS can use for anything.

GUD is a wire protocol rather than a Linux one, so the host end is not fixed. A
Windows driver over IddCx would work against the same hardware unchanged -- that is
**M7**, and it will most likely live in its own repository, since such a driver is
useful to any GUD device and not just this one.

This is a different approach from the emulator-driven path. There, a guest has
to run something like GroovyMAME with exact modelines and beam-timed updates to
push frames. Here the work happens at the kernel driver layer on the host, and
GUD's damage-rectangle model means only changed pixels cross the wire. The
device takes those rectangles into scanout memory and reads them out as a 15kHz
raster.

A few specifics, since they are easy to assume wrong:

- **No compression on the wire, for now.** GUD can negotiate LZ4 and the device
  declines it. The 240p modes fit raw with room to spare -- a 384x224p60 frame in
  RGB565 is 10 MB/s against USB 2.0's ~35 MB/s of bulk, full-screen motion and
  every pixel changing. The 640-wide modes are the ones that need help, and by
  about five per cent. See **M5**.
- **The transport is the general-purpose HPS port, not AXI or DMA.** Register
  and pixel access marshals through the 32-bit `gp` interface the board already
  brings out. The seam that carries it (`rtl/blitscrt_bridge.v`) can be switched
  to the lightweight AXI bridge with one parameter, but the built path is the
  simpler gp one.
- **It is a blit streamer, not a line-by-line transceiver with no memory.** The
  device holds scanout memory; the raster reads from it on the pixel clock while
  the host writes into it whenever it likes. See **Lineage** for why that
  storage is required and why it is still a streamer.

The host does the rendering. The board is a USB-to-CRT display that happens to
be an FPGA.

## Relationship to MiSTer

blitsCRT_Mister is not a MiSTer core. It does not use the MiSTer framework,
`hps_io`, the OSD, or the MiSTer menu, and it does not run any MiSTer core. It
runs its **own** kernel on the MiSTer hardware.

What it borrows from a MiSTer card is the low-level boot: the A2 preloader (which
brings up DDR3 and the HPS pin mux) and the u-boot binary. Above that, BlitsCRT
replaces the environment entirely. u-boot is repointed to program `blitscrt.rbf`
onto the fabric and boot the BlitsCRT kernel directly, with no menu, no `.rbf`
hand-off, and no MiSTer Linux. It is a **dedicated boot**: this card powers
straight into BlitsCRT.

Because the kernel is ours, the USB OTG port can be put in peripheral mode, which
the GUD host link needs and which the stock MiSTer kernel, being USB-host only,
cannot do.

The boot procedure is in **Bringing up the HPS side** below.

## What it does

- Analog RGB666 out of the A/V board. The same stream out of HDMI as Direct Video
- Eight-bar colour test card, half-amplitude bars, 16-step greyscale ramp,
  one-pixel border, centre crosshair
- Idle screen giving mode, line rate, pixel clock, porch numbers, host status
  and which outputs are live
- `BTN_OSD` cycles the mode. `BTN_USER` hides the overlay. `BTN_RESET` resets
  the video pipeline

### Modes

Modes are dynamic. The point of the whole thing is that the host names a
timing and the board produces it, which is how Switchres works: a modeline per
game, arbitrary pixel clocks, nothing fixed in advance.

The software side already does this. `sw/modes.c` takes any DRM mode a host
hands over, checks it against what a 15kHz CRT will survive, and `sw/pll.c`
solves the PLL counters for the clock. Worst case across real console and
arcade timings is 6 ppm. The mode list itself is dynamic too: modes can be
added at runtime and the host re-reads them without re-enumerating the USB
device.

### What the daemon advertises

Four modes, with 640x480i60 first and flagged `PREFERRED`, which is what a host
picks on first connect.

| mode | pixel clock | line | field | |
|---|---|---|---|---|
| **640x480i60** | 12.600 MHz | 15.750 kHz | 60.00 Hz | preferred, NTSC 480i |
| 640x576i50 | 12.500 MHz | 15.625 kHz | 50.00 Hz | PAL 576i |
| 320x240p60 | 6.300 MHz | 15.750 kHz | 60.11 Hz | NTSC 240p |
| 320x288p50 | 6.250 MHz | 15.625 kHz | 50.08 Hz | PAL 288p |

Each 320-wide mode is exactly half its 640-wide partner, and the counters fall
out of the same VCO:

```
640x480i60   12.600 MHz   VCO 1575   C=125      NTSC pair
320x240p60    6.300 MHz   VCO 1575   C=250
640x576i50   12.500 MHz   VCO  800   C=64       PAL pair
320x288p50    6.250 MHz   VCO  800   C=128
```

Two VCOs cover all four, and within a VCO the 640 and 320 modes are one counter
apart. All four solve to 0 ppm. That is how the PLL is driven: reconfigure M and N
to swap VCO between NTSC and PAL, and take the two C outputs into the clock mux
for 640-wide against 320-wide. Two muxed PLL outputs is exactly what `altclkctrl`
allows.

This is the advertised list, not a limit. A host can set a timing that was never
in it, which is the Switchres case.

The fabric has three built-in modes, driven from its two compiled pixel clocks.
Anything beyond them is reached by reconfiguring the PLL at runtime:

| | mode | pixel clock | line | field | for |
|---|---|---|---|---|---|
| 0 | 640x240p60 | 12.600 MHz | 15.750 kHz | 60.11 Hz | 15kHz CRT |
| 1 | 640x480i60 | 12.600 MHz | 15.750 kHz | 60.00 Hz | 15kHz CRT, standard 480i |
| 2 | 640x480p60 | 25.200 MHz | 31.500 kHz | 60.00 Hz | any VGA or HDMI display |

Modes 0 and 1 share a clock. Switching between them never touches the PLL.

The timing generator itself has no built-in modes. Porches, active size and the
interlace flag are all inputs, latched while the pipeline is held in reset. It
will drive whatever timing it is given. Only the clock is pinned.

## What the screen reports at boot

The board can be in three states, and the overlay distinguishes them so a dark
or wrong screen points at the right layer.

**Fabric only.** The FPGA is programmed and drawing the test card, but the HPS
is silent: Linux has not booted, or `blitscrtd` is not running. The overlay
shows a dedicated banner naming that state. This is the screen shown from
u-boot loading the `.rbf` with nothing else up.

**HPS up, no host.** The daemon is running and its heartbeat is fresh, but no
PC has enumerated the USB gadget. The overlay is the daemon's live one, with a
`USB NO HOST` line. Linux booting has nothing to do with a host being attached;
the board runs fine with the cable unplugged.

**Streaming.** A host is attached and pixels are arriving.

The mechanism is a heartbeat register the daemon bumps a few times a second and
a watchdog in the fabric that counts fields since it last changed. Past about a
second and a half of silence the fabric declares the HPS down and falls back to
its own baked banner. When the daemon is alive its text wins. The daemon also
writes a host-status hint, since only it knows the USB state.

The heartbeat is why the gadget loop polls with a timeout instead of blocking
on USB events: it has to keep ticking while idle, or the fabric would decide the
daemon had died every time no host was attached.

## Layout

```
rtl/        the design
  blitscrt_top.v     top level, pad drivers, mode selection
  video_timing.v    15kHz timing, progressive and interlaced
  testcard.v        colour bars, ramp, border, crosshair
  overlay.v         8x8 text compositor
  char_ram.v        overlay character buffer, written from the HPS side
  font_rom.v        8x8 font
  mode_table.v      the three modes, detection and button cycling
  blitscrt_regs.v   Avalon-MM register file and the bus/video clock crossing
  blitscrt_bridge.v the HPS-to-fabric seam, lightweight bridge or gp ports
  blitscrt_hps.v    the HPS general-purpose interface, isolated
  pll_modes.v       one PLL, two outputs, glitch-free mux
  adv7513_init.v    HDMI transmitter setup, Direct Video register table
  i2c_master.v      write-only I2C master feeding it
  font8x8.hex       generated
  banner.hex        generated
rtl/mister/ lifted from MiSTer, unmodified, GPL-2. sysmem_lite (the f2sdram
            path) and the safe terminator it instantiates. Kept apart so what is
            ours and what is theirs is never in doubt -- see its own README
sw/         GUD device daemon (M2 onward)
  gud.h             protocol, mirrored from the kernel header
  device.c          control requests, no USB in it
  modes.c           mode validation, DRM timing to fabric timing
  pll.c             Cyclone V counter search for arbitrary pixel clocks
  fabric.c          register access over the lightweight bridge
  gadget.c          FunctionFS transport
  blitscrt_regs.h   the fabric/software register contract
quartus/    project, pin assignments, constraints
sim/        testbenches and rendered output
tools/      font, banner, PNG and u-boot override generators
docs/       BRINGUP.md    step by step to first picture
            DESIGN.md     how it works: modes, the write path, the solver
            ROADMAP.md    milestones in detail, and what each one cost
            BOOT.md       how the bitstream reaches the FPGA
            UBOOT_ENV.md  the boot environment: importing, changing, recovery
```

**Bringing it up for the first time: `docs/BRINGUP.md`.**

## Prerequisites

### Hardware

| | |
|---|---|
| Board | MiSTer Pi, or a DE10-Nano. Cyclone V SE 5CSEBA6U23I7 |
| Video | MiSTer analog A/V board |
| SD card | A MiSTer card for its A2 preloader and u-boot binary. BlitsCRT then repoints u-boot to boot its own kernel — a dedicated card, not a MiSTer install. Cards over 32 GB are exFAT |
| Display | A 15kHz CRT, plus a VGA-to-SCART cable from the A/V board, or an HDMI-to-VGA DAC or direct-video HDMI-to-SCART cable from HDMI |
| Optional | Micro-B USB cable for the UART console on the back panel |

### Software

The quickest path is `make setup`, which installs everything the package manager
can provide and offers to clone a kernel tree:

```
make setup           # install deps, offer to clone a kernel tree
make setup-dry       # show what it would install, change nothing
make get-toolchain   # download a prebuilt ARM cross-compiler (Bootlin)
make kernel-clone    # clone the MiSTer kernel tree (non-interactive)
```

It covers the testbench and render toolchain, the ARM cross-compiler, `dtc`, and
`git`, on Arch, Debian, Fedora, or openSUSE. Two things it cannot install, since
neither is a package: **Quartus Prime Lite** (a manual, licensed download — tick
the Cyclone V device family during install) and the **kernel tree** itself,
though it offers to clone one at the end.

The full list, for installing by hand:

| | | |
|---|---|---|
| Quartus Prime Lite | required for the bitstream | Tested against 24.1. Cyclone V ticked during install. Not a package — install by hand |
| Python 3 | required | Generates `font8x8.hex` and `banner.hex`. A bare install is enough |
| Icarus Verilog | optional | Runs the testbenches |
| Pillow | optional | `make render` |
| ARM cross-compiler | for the kernel | Repo package on Debian/Fedora; a prebuilt tarball (Arm, Bootlin) on Arch. Auto-detected |
| dtc | for the kernel | Device tree compiler |
| git | for the kernel | To check a kernel tree out |
| A kernel tree | for the kernel | MiSTer's `Linux-Kernel_MiSTer` or a mainline `linux-socfpga` |

```
# Arch -- repo tools from pacman, cross-compiler as a prebuilt tarball (below):
sudo pacman -S iverilog python-pillow dtc git

# Debian -- everything from the repos:
sudo apt install iverilog python3-pil device-tree-compiler gcc-arm-linux-gnueabihf git
```

On Debian and Fedora the ARM Linux cross-compiler is a normal repo package. On
Arch it is not — and the AUR package builds the entire toolchain from source
(gcc, glibc, binutils), which is slow and fails easily. Use a **prebuilt
toolchain** instead: download one, extract it, put its `bin/` on `PATH`.

- Arm's GNU toolchain: <https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads>
  — pick the AArch32 hard-float target (`arm-none-linux-gnueabihf`).
- Bootlin: <https://toolchains.bootlin.com> — armv7-eabihf, glibc.

Or let the build fetch one:

```
make get-toolchain      # download + extract a Bootlin ARM toolchain
```

This pulls the Bootlin `armv7-eabihf glibc` stable build (a prebuilt tarball, no
compilation), verifies its checksum, and extracts it to `~/toolchains/`. The
build then auto-detects it there — no `PATH` edit needed — or add its printed
`bin/` to `PATH` to use it in other projects. Its triplet is
`arm-buildroot-linux-gnueabihf-`, already in the auto-detect list.

It is a separate command from `make setup`, and on purpose: it downloads ~150 MB
from a third-party server and drops a toolchain on disk, which should be a
deliberate choice rather than a side effect of installing packages. `make setup`
installs the small repo tools and points here for the compiler. Either way
the kernel step skips until a compiler is found — the fabric build never needs
one.

The stable build is chosen over bleeding-edge because its older kernel headers
are the safer match: a toolchain's headers version wants to be no newer than the
kernel being built against, and the MiSTer SoC kernel is not new.

`make tools` reports what is present:

```
python3    Python 3.13.7
iverilog   /usr/bin/iverilog
Pillow     present
quartus_sh /home/ben/intelFPGA_lite/24.1std/quartus/bin/quartus_sh
```

Quartus does not add itself to PATH when it installs. `make quartus-path`
locates it and prints the `export PATH=` line.

If a compile stops with a device error, Cyclone V was not selected during
install. Check with:

```
ls ~/intelFPGA_lite/*/quartus/common/devinfo/
```

`cyclonev` must appear in that list.

## Build

```
make world      # everything: assets, testbenches, renders, bitstream, kernel, build set, manifest
```

Steps whose tool is missing are skipped instead of fatal, and the manifest at
the end lists every output with its path and size. That is the single command
for the lot.

The individual targets:

```
make              # assets, then the testbenches if Icarus is present
make assets       # just the generated .hex files Quartus reads
make sim          # timing and I2C testbenches
make lint         # elaborate the real top level against primitive stubs
make check-pins   # every port has a pin, and the pins match MiSTer
make check-decl   # no identifier used before it is declared
make check-ip     # generated PLL megafunctions carry the right settings
make render       # render a 640x240p60 frame from the RTL to PNG
make render-i     # same for 640x480i60
make bitstream    # find quartus_sh and compile, and generate the u-boot override
make kernel-config          # apply defconfig and merge the gadget fragment
make linux                  # configure, build, and stage the kernel + dtb
make build        # stage a bootable set (.rbf, .txt, kernel) into build/
make uboot-txt    # just the u-boot override
make quartus-path # locate Quartus and print the export PATH line
make preview      # self-contained HTML of this README, video playable
make manifest     # list every output and whether it exists
make tools        # report which tools are installed
make sd DEST=     # copy bitstream + BlitsCRT kernel to a mounted card
make clean        # remove all transient build products (safe if none exist)
make distclean    # also remove generated assets and the Quartus output
```

`make check-decl` catches identifiers used before they are declared. Icarus
builds disagree about whether that is legal, and Quartus never objects. It
surfaces as a build failure on someone else's machine. It has caught this twice.

`make check-pins` is the one worth running after any change to the top-level
port list. A port with no location assignment gets auto-placed by the Fitter
onto an arbitrary ball. `make world` runs it first for that reason.

```
make check-pins MISTER=/path/to/Template_MiSTer   # also cross-check the pins
make bitstream QUARTUS_SH=/path/to/quartus_sh     # force a Quartus install
```

`make preview` renders this file to a single HTML with every image, GIF and
video inlined as a data URI. It also turns the `.mp4` link below the runtime
clip into a real `<video>` element. GitHub strips `<video>` out of markdown. On
GitHub that line is a download link and the GIF is what moves; the preview plays
it properly.

Only the generated assets are required before Quartus. Icarus Verilog and
Pillow are verification tools; the bitstream does not depend on either.

### Quartus version

No version is pinned. The only requirement is a Quartus that carries Cyclone V
device support, which covers Prime Lite from 15.1 through 24.1 at least.
Nothing in the design depends on a particular release. Built and tested on
24.1std.

The 17.0.2 that MiSTer pins itself to is a convention for cores built on their
framework. Nothing here uses it.

```
make bitstream
```

Quartus does not put itself on PATH when it installs. The lookup checks PATH
first, then `/opt/intelFPGA_lite`, `/opt/intelFPGA`, `/opt/altera` and the same
three under `$HOME`, matching any version directory. With several installed it
takes the newest by version sort. Force a particular one with:

```
make bitstream QUARTUS_SH=/path/to/quartus_sh
```

`make quartus-path` reports which it found, how many are installed, and the
`export PATH=` line for setting it by hand.

Two version-sensitive things, both with a fix in `docs/BRINGUP.md`: the device
family must have been ticked at install time, and a newer Quartus may refuse
`altddio_out`, which the `HDMI_CLK_DIRECT` macro works around.

For the interlaced build, uncomment the `MODE_640x480i` macro in
`quartus/blitscrt.qsf` and regenerate the banner:

```
python3 tools/gen_banner.py rtl/banner.hex 640x480i60
```

## Where things land

### The build set

`make world` builds everything its toolchains allow and ends by staging the
build set. Both the Quartus install and the kernel tree are auto-detected the
same way: if Quartus is on the path or in a standard install location the
bitstream builds, and if a configured kernel tree sits in a usual place
(`~/source/linux-socfpga`, `~/source/Linux-Kernel_MiSTer`, and similar) the
kernel builds — no flags. Point `KERNEL_SRC=...` at a tree elsewhere to override.
`make build` stages on its own. Either gathers what the board loads at power-on
into `build/`, laid out to mirror the SD card:

- `blitscrt.rbf` — the FPGA bitstream, if `make bitstream` has produced one
- `blitscrt/zImage` and `blitscrt/blitscrt.dtb` — the BlitsCRT kernel (with the
  initramfs embedded) and its device tree, if a kernel tree was found or
  `make linux` has built them, in the `blitscrt/` subfolder the boot env loads from
- `blitscrt/gadget-setup.sh` and `blitscrt/blitscrt_gadget.config` — the runtime
  USB setup and kernel options, for the GUD gadget
- `blitscrt.txt` — a generated u-boot override, retained but no longer used: the
  boot now repoints u-boot's saved environment (`tools/blitsenv.txt`) instead of
  relying on the MiSTer menu hand-off

The `build/` tree mirrors the card: `.rbf` at the top, kernel and runtime files
under `blitscrt/`. Copy its contents to the card root, then set the u-boot
environment once (see **Bringing up the HPS side**) and the board boots straight
into BlitsCRT.

`make bitstream` runs this automatically once it has produced a `.rbf`. A
successful compile leaves `build/` ready without a second command. Running
`make build` on its own stages whatever is present.

Pieces whose toolchain is absent are reported, not faked: without Quartus there
is no `.rbf`, without a kernel tree no `zImage`, and `make build` says so rather
than staging a half-set silently.

## Bringing up the HPS side

BlitsCRT boots its own kernel. The old model, selecting the `.rbf` from the
MiSTer menu and letting MiSTer's u-boot hand off, is gone: this card boots
straight into BlitsCRT.

### The BlitsCRT kernel

`make world` builds a branded kernel from the MiSTer kernel tree: a `zImage` with
an embedded initramfs, plus the device tree, versioned `BlitsCRT-0.10-k2`
(`LOCALVERSION`, so `uname -r` reads `5.15.1-BlitsCRT-0.10-k2`).

`BLITSCRT_KREV` is a kernel image revision, separate from the project version and
bumped whenever anything baked into the zImage changes -- the config fragments or
the initramfs init. Without it every build produced the same version string and
there was no way to tell a new kernel from the one already on the card, which is
the same fault as a fabric that does not bump its `VERSION` register: a fix that
did not reach the hardware looks exactly like a fix that did not work. Bumping it
also forces a rebuild, since the version string is linked in. The initramfs is a
single static `init` plus a static busybox, built into the image, so there is no
separate rootfs to ship. On boot `init` brings up `/proc`, `/sys` and `devtmpfs`,
mounts the card (exFAT on cards over 32 GB, FAT32 below), appends a stamped record
to `/media/fat/blitscrt-boot.log`, and drops to a busybox shell on the serial
console.

The kernel options beyond the base config live in `linux/blitscrt_boot.config`
(embedded initramfs, exFAT and FAT, the DesignWare SD/MMC driver, the HPS UART
console) and `linux/blitscrt_gadget.config` (dwc2 dual-role, FunctionFS, configfs
-- the USB-gadget stack the GUD link needs).

### The boot set

`make world` stages, under `build/`, everything the card needs:

| file | on the card | what it is |
|---|---|---|
| `blitscrt.rbf` | `/blitscrt.rbf` | the fabric bitstream, programmed by u-boot |
| `zImage` | `/blitscrt/zImage` | the BlitsCRT kernel, initramfs embedded |
| `blitscrt.dtb` | `/blitscrt/blitscrt.dtb` | the device tree |
| `blitsenv.txt` | imported into u-boot | the u-boot environment (below) |

`make sd DEST=/path/to/mounted/card` copies the first three to the card root. The
card's FAT/exFAT partition also carries the MiSTer preloader and u-boot that the
A2 boot chain needs.

### The u-boot environment

The one non-file step. BlitsCRT boots by pointing u-boot's saved environment at
our kernel instead of MiSTer's. `tools/blitsenv.txt` is that environment:

```
core=blitscrt.rbf
bootcmd=... run fpgaload; load ... blitscrt/zImage; load ... blitscrt/blitscrt.dtb; ... bootz 0x01000000 - 0x03000000
```

`run fpgaload` is MiSTer u-boot's own routine -- it loads `blitscrt.rbf` and
`fpga load`s it into the fabric -- now pointed at our core; then the kernel and
device tree load and `bootz` starts BlitsCRT. The initramfs is inside the
`zImage`, so there is no `root=`. The kernel loads at `0x01000000` and the dtb at
`0x03000000`, a 32 MB gap that keeps the growing kernel image clear of the dtb.

Install it once from the u-boot serial console. This is a **dedicated card** -- it
replaces MiSTer's boot on it, so back up first:

```
load mmc 0:1 0x01000000 blitsenv.txt
env import -t 0x01000000 $filesize
saveenv
reset
```

Break into u-boot by holding a key at power-on (bootdelay is 0). u-boot stores its
environment in the MMC (offset 512), so `saveenv` persists it with no u-boot
rebuild. After that the card boots straight into BlitsCRT on every power-up.

Watch it on the HPS UART at 115200: programming the fabric, the kernel boot, the
mount and the log all appear there.

## HDMI

The 15kHz stream goes out of the HDMI connector unscaled. An HDMI-to-VGA DAC or
a direct-video SCART cable converts it back to analog at the far end. The line
rate is untouched at 15.7 kHz.

Register `0x3B = 0x00` is what makes this work. It selects automatic pixel
repetition, and the ADV7513 then handles a pixel clock below its own minimum by
repeating internally. MiSTer sets the same value when `direct_video` is on.
`0xAF = 0x04` selects DVI mode, dropping infoframes that nothing downstream
reads.

MiSTer does this configuration in software. `sys_top.v` routes HDMI I2C to the
HPS and the MiSTer binary writes the registers from Linux. This fabric runs
with no software at all.
`adv7513_init.v` carries the same table and walks it over a fabric I2C master,
replaying about twice a second to catch a display plugged in later.

`LED_HDD` lights once the transmitter acks the whole table. If it stays dark the
I2C bus is not answering. Look at wiring and address before video.

`direct_video=1` in `MiSTer.ini` has no effect on this bitstream. The equivalent
is compiled in.

## Notes on the hardware

### What is needed

| | | |
|---|---|---|
| **DE10-Nano or MiSTer Pi** | required | the board itself |
| **Analog A/V board** | required | the only 15 kHz RGB output; without it there is HDMI and nothing else |
| **microSD card** | required | dedicated to BlitsCRT, since it replaces the boot chain on it |
| **A-to-A USB cable, VBUS cut** | required for M4 | host link, into the board's Type-A OTG port |
| **Serial console** | advisable | the HPS UART at 115200 is where the boot log and the daemon appear |
| **SDRAM module** | not used | no controller in the design, and none planned |
| **USB hub board** | must be removed | the gadget does not work with it fitted |
| RTC board | not used | nothing here needs it |

The host link goes into the board's USB OTG port, driven by the HPS `dwc2`
controller in peripheral mode. On a DE10-Nano that is the micro-AB connector; a
MiSTer Pi fits a **Type-A** receptacle instead, so the cable is A-to-A with VBUS
cut on the board side -- both ends look like hosts and only one of them may supply
power.

The micro-USB visible on an assembled MiSTer Pi is easy to mistake for the OTG
port and is not: it belongs to the USB hub add-on and is that hub's *upstream*
input. A PC plugged into it becomes the hub's host and enumerates a 7-port hub,
which looks like the gadget failing and is nothing of the kind.

The hub add-on has to come off. It reaches the same `dwc2` controller, so both it
and the gadget end up on the bus the host is trying to enumerate, and the gadget
does not work while it is fitted -- established on hardware, not inferred.

That is the awkward part of this board for M4: the hub is what a normal MiSTer
build uses for keyboards and joysticks, and it and the display gadget cannot both
have the controller. Nothing in the design can arbitrate it; a USB device is a
transceiver with a pull-up, and there are two of them on one pair.

Which socket reaches the controller is a board question, answered on the board:

```
ls /sys/class/udc/          # names the gadget controller, if one exists
dmesg | tail -20            # then plug a host in and compare
```

An empty `/sys/class/udc/` means no gadget controller is registered at all, which
is `dr_mode` rather than the cable. That is where this board stands today, and it
is the first M4 task.

The analog board is the one that matters. Its VGA is a six-bit resistor ladder per
channel wired straight to FPGA pins -- there is no DAC chip in the path -- which is
why the design outputs RGB666 natively and why the format list is ordered the way
it is. Without that board the fabric still runs and HDMI still works, but the
15 kHz output that is the point of the project has nowhere to go.

### The analog path

VGA on the analog A/V board is a six-bit resistor ladder per channel wired
straight to FPGA pins. There is no DAC chip in the path. The design outputs
RGB666 natively.

Pin assignments in `quartus/pins.tcl` come from the MiSTer framework's `sys.tcl`
and `sys_analog.tcl`. They describe board wiring.

`make check-pins` verifies that every port on `blitscrt_top` has a location
assignment. A port without one gets auto-placed by the Fitter onto an arbitrary
ball, which is how a design ends up with its clock on the wrong pin and no
picture. It runs as part of `make world`.

Point it at a MiSTer checkout to cross-check the assignments themselves:

```
make check-pins MISTER=/path/to/Template_MiSTer
```

Last run against MiSTer master:

```
blitscrt_top ports:      59
active pin assignments:  59
commented out (for M3):  39

PASS  every port has a location assignment

cross-check against MiSTer (145 reference assignments):
  compared  98
  mismatch  0
  not in reference  0
```

The 39 commented assignments are the SDRAM module, verified against the same
reference and ready for M3. The 47 MiSTer signals with no counterpart here are
audio, SDIO, the ADC, the user IO header and the DE10-Nano's own LEDs and
switches, none of which this design touches.

These assignments describe the DE10-Nano with the official I/O board. They hold
on the MiSTer Pi with the A/V Pro because MiSTer cores run there unmodified,
and every signal used here is actively driven or read by `sys_top.v` — the
clock, all three colour channels, both syncs, the board detect, the LEDs, the
buttons, the whole HDMI bus and its I2C. Working cores exercise every one of
them.

The one thing that departs from MiSTer is what drives HDMI I2C. `sys_top.v`
routes those two pins to the HPS and configures the ADV7513 from Linux.
`adv7513_init.v` drives the same pins from fabric instead. They are FPGA I/O
either way and the pad behaviour is identical. What is new here is the I2C
master and the register table. `LED_HDD` reports whether the transmitter acked
it.

`VGA_EN` is an input with a weak pull-up. The A/V board pulls it low. With no
board fitted the VGA pins are released. Check that pin first on a dark screen.

Sync is driven active low for 15kHz RGB and SCART. The `CSYNC` parameter on
`blitscrt_top` puts composite sync on the HS pin for SCART pin 20.

The pixel pipeline is five clocks deep from the raw counters and sync is delayed
to match. An error here shifts the picture within the active window and moves
the porches the CRT centres on.

Unused pins are reserved as tri-stated inputs. The design cannot drive the
SDRAM, the HPS GPIO, or anything else it has no assignment for.

## Restarting the daemon with logging

`init` starts `blitscrtd` at boot, writing to `/media/fat/blitscrtd.log`. LZ4 is
on -- that is the daemon's own default rather than something the boot path sets,
so it applies however the daemon is started. `BLITSCRT_LZ4=0` turns it off.

To watch what it is doing, stop it and start it by hand:

```
killall blitscrtd
BLITSCRT_TRACE=1 BLITSCRT_GP_UNSAFE=1 \
    /media/fat/blitscrt/blitscrtd > /media/fat/trace.log 2>&1 &
```

The `&` matters -- without it the daemon holds the console and there is no shell
to read the log from. `killall blitscrtd` stops it; init does not respawn it.

Then:

The report leads with the running mode and the achieved rate:

```
blitscrtd: 640x480i host timing -- 45.9 fps -- wait 6.6 ms, xfer 0.0 ms,
           lz4 3.0 ms, blit 5.6 ms, critical path 8.6 of 21.8 available
```

`critical path` against `available` is the question worth asking. The device uses
roughly 9 ms of a 16.7 ms budget, so if `available` is much larger than that the
frames are simply not arriving and the cause is upstream -- a flaky USB hub on the
host produced exactly that, and nothing on this side would have helped. `wait` is time between asking for a rect and the first
byte arriving; `xfer` is first byte to last. `xfer 0.0` means the frame was
already buffered when the read was issued -- no transfer bottleneck at all.

The mode is on the line because there is no other way to see it while the daemon
runs: `blitscrt-peek` needs the daemon stopped, and stopping it clears
`HPS_TIMING`, so a peek always reports the front-panel table whatever was on
screen. The overlay would say, but it hides itself when a host attaches.

Which build is on the card, without running it:

```
grep -a -o 'blitscrtd-build=[a-z0-9]*' /media/fat/blitscrt/blitscrtd
```

Grep for the bare number instead and it will mislead: a static ARM binary carries
the VFP register names `d0` to `d31` in its unwind tables, so searching for `d16`
finds one of those.

```
tail -40 /media/fat/trace.log          # what it is doing now
grep -c 'LZ4 block bad' /media/fat/trace.log     # should be 0
grep -c 'header said'   /media/fat/trace.log     # should be 0
grep 'fps' /media/fat/trace.log | tail -5        # rate against the budget
```

**The trace slows it down, and enough to change what it measures.** It prints two
lines per frame; at 60 Hz over a 115200 console that is far more than the line can
carry, so the writes back up and the daemon waits on them. Frame rate drops, and
the numbers in the report describe a machine that is busy logging. Redirecting to
a file rather than the console helps but does not eliminate it -- the card is not
fast either.

So: use it to find out *what* is happening, not *how fast*. For rate, run without
`BLITSCRT_TRACE`; the once-a-second line is still printed and reads

```
blitscrtd: 60.0 fps -- read 1.5 ms (overlapped), lz4 2.6 ms, blit 5.6 ms,
           critical path 8.2 of 16.7 available
```

which is the useful measurement. `critical path` well under `available` means the
daemon is idle waiting for frames, so a shortfall is the host rather than this
end.

One more thing worth knowing: a trace left running on a serial console has been
seen to leave a `screen` session spinning at 100% CPU on the host afterwards. If
frame rate is mysteriously poor, check `top` on the PC before suspecting the
board.

### Checking what the host thinks it has

Desktop settings panels show resolution and refresh and little else -- KDE does
not display interlace or preferred flags at all, which makes it easy to conclude
something is wrong when it is not. `modetest` shows what DRM actually has:

```
sudo modetest -c | grep -A3 640x480
```

```
#0 640x480i 60.00 640 664 724 800 480 486 492 525 12600 flags: nhsync, nvsync, interlace; type: preferred, driver
#1 640x576i 50.00 640 664 724 800 576 582 588 625 12500 flags: nhsync, nvsync, interlace; type: driver
#2 320x288   50.08 320 332 362 400 288 291 294 312  6250 flags: nhsync, nvsync; type: driver
#3 320x240   60.11 320 332 362 400 240 243 246 262  6300 flags: nhsync, nvsync; type: driver
```

Every advertised mode, with its timings, its sync polarity, and `interlace` on
the two that carry it. That is the authority on the host side; `blitscrt-peek -t`
is the authority on the board, reading the `LIVE_*` registers after the mux.

## The GUD daemon

`sw/` holds the device side of the Generic USB Display protocol. It answers
every control request, validates modes against what a 15kHz CRT will survive,
and solves PLL counters for pixel clocks it has never seen.

```
cd sw
make test                                # no hardware needed
make CROSS_COMPILE=arm-linux-gnueabihf-  # for the target
```

The protocol layer has no USB in it. The whole control surface runs under
test:

```
worst error 6 ppm, worst search 3026 candidate evaluations     test_pll
counter encoding round-trips across every divide to 510        test_pll_reconfig
12 modelines validated or correctly refused                    test_modes
33 assertions: enumeration, modeset, flush, dynamic modes      test_device
```

How the solver and the reconfiguration work is in `docs/DESIGN.md`.

## Status

| | |
|---|---|
| **M1** fabric only | done -- 15kHz out of both connectors |
| **M2** custom kernel and runtime control | done -- own kernel, own init, registers over gp |
| **M3** scanout memory | done -- HPS DDR3 over f2sdram, custom pixel clocks by PLL reconfiguration |
| **M4** GUD USB host link | done -- a host enumerates it as a display and drives it |
| **M5** bandwidth | done -- LZ4, 60 fps full-screen. RGB888 still needs a two-beat read window |
| **M6** Switchres modes at boot | not started -- monitor profiles and a generated mode list |
| **M7** Windows host | not started, and probably its own repository |

Detail, including what each milestone cost to get working, is in
`docs/ROADMAP.md`.


## Known limitations

- Mode 0 is **640**x240, not 320x240. It went 640 wide when I dropped to two
  clocks. Same raster, 15.750 kHz and 262 lines, just twice the horizontal
  sample density. The scanout path now pixel-doubles 320-wide memory to fill it,
  so a true 320-wide active area is back for scanout; the test card is still
  generated at 640.
- 640x240p is not a format HDMI sinks recognise. The transmitter sends it and a
  Direct Video DAC converts it, but a monitor may refuse to lock. Mode 1 is the
  HDMI default for that reason.
- The fabric has two compiled pixel clocks, 12.600 and 6.300 MHz, which is what
  the three built-in modes use. Anything else is reached by reconfiguring the PLL
  at runtime, so the advertised mode list depends on `altera_pll_reconfig` working
  rather than treating it as an extra.
- HDMI hot plug detect is inferred from the transmitter acking I2C. I never
  read its HPD register, because `rtl/i2c_master.v` is write-only.
- `STAT_APPLYING` is not trustworthy across a PLL reconfiguration. The PLL losing
  lock resets `apply_ack` in the video domain while `apply_req` keeps its value in
  the bus domain, so the toggle handshake can come back disagreeing and latch the
  staged timing spontaneously. `set_mode()` works around it by confirming against
  `LIVE_*`, and the underlying handshake is still wrong.

- `MODE_640x480p` selects slot 3 expecting 25.200 MHz, and the PLL puts 6.300
  there, so the 31 kHz diagnostic runs at 7.875. Left alone deliberately: it is
  not a 15 kHz target, and putting 25.200 on `outclk_1` would cost 320x240p60.

- **The I/O board LEDs and buttons do not work on a MiSTer Pi.** They are behind
  an **MCP23009 I2C GPIO expander**, not on the GPIO pins this project drives.

  MiSTer's `sys_top.v` instantiates an `mcp23009` module bit-banging I2C on
  `IO_SCL`/`IO_SDA`, and when the expander answers, everything moves: the buttons
  come from it rather than `BTN_*`, and the `LED_*` pins are reused for other
  signals -- `LED_USER` becomes `VGA_TX_CLK` outright. So on such a board those
  pins are not merely unused, they mean something else, which is why
  `blitscrt-peek -i` shows the fabric driving them correctly to no effect.

  Note the bus is FPGA-side, bit-banged by the fabric. Looking for it in
  `/sys/bus/i2c` finds only the RTC board and gets nowhere.

  **`rtl/mcp23009.v` implements the device side**, with `rtl/i2c_master.v`
  extended for single-byte reads, and `sim/tb_mcp23009.v` checks it against a
  model expander -- the init sequence, LED bit order, button decoding, and that
  an absent expander reports nothing pressed rather than phantom presses.
  Register layout follows MiSTer's `sys/mcp23009.sv`, (C) 2019 Alexey Melnikov,
  GPL-2.0-or-later.

  **Not yet wired up**: `IO_SCL`/`IO_SDA` need pin assignments, and those are in
  MiSTer's `sys/sys.tcl` rather than anywhere this project can derive them. Once
  they are in `pins.tcl`, the module needs instantiating in `blitscrt_top.v` with
  its `btn` output feeding the existing button logic and `present` selecting
  between it and the GPIO pins.

- The connector shows as `VGA-1-unknown` on a host, because no EDID is sent. One
  is implemented in `sw/edid.c` -- a monitor name and a sync range, and no timings
  at all, on the reasoning that a host cannot prefer a mode it has not been given.
  Sending it breaks mode selection: the host picks a mode wider than the raster
  and drops frames, with a bare name descriptor as much as with range limits.
  Both variants lack any timing descriptor, which is the likely cause and is
  written up in `sw/edid.c`. `BLITSCRT_EDID=name` or `=full` for anyone
  investigating.

- RGB888 is not offered, though it is the only format that uses the whole 6/6/6
  ladder. `scanout_fetch.v` cannot read three bytes per pixel: it straddles the
  64-bit beat boundary, and the lane extractor handles 1, 2 and 4-byte formats.
  It was advertised first until a host took it and produced a picture whose
  stride drifted across every line. RGB565 is what works, at the cost of a bit on
  red and blue. The two-beat read window that brings it back is M5 work.


- `blitscrt.nogadget` on the kernel command line skips USB gadget staging and
  boots as before M4: fabric, daemon, shell. Edit `blitsenv.txt` on the card; no
  rebuild needed. Worth knowing while the gadget path is new.

- The USB hub add-on must be removed for the gadget to work. It reaches the same
  `dwc2` controller, and a USB device is a transceiver with a pull-up: two of them
  on one pair is not something software can arbitrate. So a board set up for
  MiSTer in the usual way cannot also be a display without pulling the hub, and
  keyboards and joysticks go with it.

## Credits and licensing

**GPL-2.0-or-later**, full text in `LICENSE`. The project began MIT and moved
when it took MiSTer's `sysmem_lite` for the f2sdram path: GPL code cannot go
into an MIT work and leave it MIT, so the combined work is GPL. Every source
file carries an SPDX line saying so.

One file stays MIT, and has to. `sw/gud.h` carries Noralf Trønnes' copyright and
the MIT permission notice, which MIT requires be retained. A GPL work may
contain MIT-licensed files provided each carries its own notice, so that header
travels with the code it covers -- which is why those definitions live in their
own file and should not be folded into a GPL-2 source file.

Four things here came from elsewhere and I want them named.

**Pin assignments** in `quartus/pins.tcl` come from the MiSTer framework's
`sys/sys.tcl` and `sys/sys_analog.tcl`. They describe how the board is wired.
`make check-pins` diffs mine against theirs.

**`sysmem_lite`** in `rtl/mister/sysmem.sv`, with `f2sdram_safe_terminator.sv`
(Copyright 2021 bellwood420) that it instantiates, come from the same MiSTer
tree and are **GPL-2.0**. They are the f2sdram path: a flattened Platform
Designer system carrying the HPS component with three FPGA-to-SDRAM ports,
checked in as SystemVerilog rather than as a project to generate.

Theirs is used rather than a system generated here because the f2sdram port
configuration is latched by `APPLYCFG` while the SDRAM interface is idle -- the
preloader's job, and something Linux cannot do at all. The A2 preloader on a
MiSTer card was built against that configuration, so a different one would not
match what is already latched.

**The GUD protocol** is Noralf Trønnes' work, MIT licensed. `sw/gud.h` mirrors
the part of `include/drm/gud.h` the device side needs. The host driver has been
in-tree since Linux 5.13. GUD lost its maintainer in January 2025 and the
upstream repo is archived, but the protocol is frozen and the in-tree driver
still works.

**The ADV7513 register table** in `rtl/adv7513_init.v` follows the sequence in
`Main_MiSTer/video.cpp`, which is GPL-2.0. Somebody else debugged that order and
I took it. Two values are mine: `0x3B = 0x00` for automatic pixel repetition,
and `0xAF = 0x04` for DVI instead of HDMI.

Every one of these is GPL-2 and so is this project, so they are borrowed on the
terms they were offered under. The register table, the pin assignments and
`sysmem_lite` all carry a notice naming where they came from, in the file rather
than only here.
