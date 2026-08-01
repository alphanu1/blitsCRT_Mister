# Bring-up, step by step

Milestone 1 from an unpacked archive to a picture on a CRT.

## What you need

Hardware:

- MiSTer Pi with the analog A/V board fitted
- A MiSTer SD card. blitsCRT_Mister borrows its A2 preloader and its hand-off
  mechanism. It cannot boot without one
- A CRT and one of:
  - VGA-to-SCART cable from the A/V board's VGA port
  - HDMI-to-VGA DAC, or a direct-video HDMI-to-SCART cable, from HDMI
- Optional but worth having: a micro-B cable for the UART port on the back

Software on the workstation:

- Quartus Prime Lite, any version with Cyclone V device support. That covers
  15.1 through 24.1 at least. Tested on 24.1std. MiSTer pins itself to 17.0.2
  for cores built on their framework, which this is not
- Python 3. Bare install is enough to generate the font and banner
- Optional: Icarus Verilog for the testbenches, Pillow for `make render`.
  Neither is needed to build the bitstream

```
sudo pacman -S iverilog python-pillow      # Arch
sudo apt install iverilog python3-pil      # Debian
```

`make tools` reports what is present and what is missing.

## 1. Unpack and check the simulation

```
unzip blitsCRT_Mister.zip
cd blitsCRT_Mister
make
```

This generates `rtl/font8x8.hex` and `rtl/banner.hex`, which Quartus needs, then
runs the testbenches if Icarus is installed. Without it the assets still build
and the run ends with a note. Nothing is blocked.

With Icarus, expected:

```
640x240p60    63.4928 us line -> 15.7498 kHz, 262 hsync/frame, 153600 pixels
640x480i60    63.4928 us line -> 15.7498 kHz, 525 hsync/frame, 307200 pixels
640x480p60    31.7456 us line -> 31.5004 kHz, 525 hsync/frame, 307200 pixels
decoded 47 transactions, 0 errors
PASS
```

This runs before Quartus is involved. If it fails, the toolchain is wrong, not
the design.

Optional, renders the test card from the RTL to `sim/`:

```
make render
make render-i
```

If you would rather do steps 1 and 2 in one command:

```
make world
```

That runs the assets, testbenches, renders and the Quartus compile, skipping
anything whose tool is missing, and prints every output path at the end.

## 2. Compile the bitstream

```
make bitstream
```

That looks for `quartus_sh` on PATH, then in the usual install roots, and
compiles. Output lands in `quartus/output_files/blitscrt.rbf`.

Quartus does not add itself to PATH on install. If the target cannot find it:

```
make quartus-path
```

which either prints the `export PATH=` line to use, or tells you how to search
for it. Doing it by hand:

```
export PATH=$PATH:/opt/intelFPGA_lite/17.0/quartus/bin
cd quartus && quartus_sh --flow compile blitscrt
```

All three modes are in one bitstream and selected at runtime. `BTN_OSD` cycles
them; `DEFAULT_VGA` and `DEFAULT_HDMI` in `blitscrt.qsf` set what comes up.

If the compile stops with "device not supported", the Cyclone V family was not
selected during install. Check which families are present:

```
ls ~/intelFPGA_lite/24.1std/quartus/common/devinfo/
```

`cyclonev` must be in that list. Add it by re-running the Quartus installer and
ticking Cyclone V under device support.

If it stops with `Assignment value ... is illegal`, Quartus names the setting,
the line, and the values it will accept. Edit `quartus/blitscrt.qsf` to match.

If it stops on `altddio_out`, rebuild with the fallback. Add this to
`quartus/blitscrt.qsf` and recompile:

```
set_global_assignment -name VERILOG_MACRO "HDMI_CLK_DIRECT=1"
```

That drives the HDMI clock pin straight from the pixel clock. It works at these
rates and costs a timing warning.

Pin assignments are cross-checked against the MiSTer framework by
`make check-pins`, which `make world` runs first. Every signal used here is one
that working MiSTer cores drive or read on this board.

## 3. Check the Fitter used the assigned pins

This is the failure that cost the last bring-up on the other board. Open the
Fitter report, find the Input/Output Pins section, and confirm every `VGA_*`,
`HDMI_*`, `FPGA_CLK1_50`, `BTN_*` and `LED_*` pin shows as user-assigned.

If the Location column is empty and Fitter Location is full of arbitrary
placements, `pins.tcl` never ran. Nothing will work, including the clock. Check
that `source pins.tcl` is still at the end of `blitscrt.qsf` and that you
compiled from inside `quartus/`.

Also confirm in the log that `$readmemh` found `font8x8.hex` and `banner.hex`.
Missing means `SEARCH_PATH ../rtl` did not resolve, and you get bars with
garbled text.

## 4. Prepare the SD card

Mount the MiSTer card's FAT partition, then from the project root:

```
make sd DEST=/run/media/you/MiSTer
```

That copies two files to the root, next to `menu.rbf`:

- `blitscrt.rbf` — the bitstream
- `blitscrt.txt` — u-boot commands

Those two are the only additions. Nothing else on the card changes, and the
install is reversible by deleting them.

They are not sufficient on their own. The card still needs its A2 partition,
`linux/`, the `MiSTer` binary and `menu.rbf`, because MiSTer's userland is what
reads the `.txt` and reboots. The script checks for these and warns.

The hand-off works from the SD card only; MiSTer disables it for cores on USB
storage. And if the root holds other `.txt` files, MiSTer shows a picker
instead of taking `blitscrt.txt` automatically.

## 5. First boot

Connect the CRT to the A/V board's VGA port, or to HDMI through a DAC. Both
carry the same picture, and having both connected is useful — if one is dark
and the other is not, that isolates the fault immediately.

Power on, let MiSTer come up, and select `blitscrt.rbf` from the menu.

The board reboots once. MiSTer stashes the contents of `blitscrt.txt` in DDR3,
u-boot picks it up on the way back, configures the FPGA, and stops before
Linux.

## 6. What you should see

```
BLITSCRT_MISTER
M1  FABRIC ONLY

MODE   320X240P 60.17HZ
LINE   15.764 KHZ
PIXEL  6.400 MHZ
H 30/32/320/24   V 3/16/240/3

USB    NO HOST
OUT    VGA RGB666 + HDMI DV
```

over eight colour bars, half-amplitude bars, a greyscale ramp, a one-pixel
border and a centre crosshair.

The default mode is 640x480i60. `BTN_OSD` toggles to 640x240p60 and back.
`LED_HDD` blinks the mode number.

`BTN_USER` hides the text so the bars can be judged unobstructed.

Power cycle to return to MiSTer.

## 7. LEDs

All three are active low on the I/O board.

| LED | Meaning |
|---|---|
| `LED_POWER` | pixel PLL locked |
| `LED_HDD` | ADV7513 acked the whole register table |
| `LED_USER` | heartbeat, roughly 1.3 Hz off the pixel clock |

A blinking `LED_USER` means the design is configured, clocked and running,
whatever the screen is doing.

## 8. If there is no picture

**Nothing on either output, `LED_POWER` dark.** The PLL is not locked. Clock pin
assignment, or `pins.tcl` did not run. Back to step 3.

**Nothing on either output, LEDs alive.** The design is running. `VGA_EN` is the
next thing to check — it is an input with a weak pull-up that the A/V board
pulls low. Read high, the VGA pins are released.

**VGA dark, HDMI fine.** A/V board jumpers, or the VGA-to-SCART cable. At 15kHz a
wrong output-mode setting looks the same as a dead output.

**Nothing on a 15kHz CRT at all.** Check HDMI first: both outputs carry the same
pixel stream, so a picture there proves the pins, the PLL, the timing generator
and the test card, leaving only the analog path. Many monitors will not lock to
640x480i60 over HDMI, so this only tells you something if one does.

There used to be a 31.5 kHz mode for exactly this, which any monitor would show.
It was removed with the rest of the 31 kHz support. If the HDMI route is
inconclusive, `blitscrt-peek -t` reports what the raster is really doing and
`-i` reports the analog board's present pin, which is the better test anyway.

**HDMI dark, VGA fine.** Check `LED_HDD`. Dark means the ADV7513 is not acking
I2C. That is a bus problem. Lit means the transmitter is configured and the
DAC downstream is the suspect.

**Picture rolls or tears vertically.** Separate sync where the display wants
composite. Set `CSYNC = 1` on `blitscrt_top` and recompile. That puts composite
sync on the HS pin for SCART pin 20.

**Bars correct, text garbled.** `banner.hex` or `font8x8.hex` was not picked up
at synthesis. Back to step 3.

**Board hangs, no reboot after selecting from the menu.** `blitscrt.txt` was not
copied, or not named to match the `.rbf`. Without it MiSTer programs the FPGA
directly and then enables the HPS-to-FPGA bridges, and M1 has no slave behind
them.

**Reboots but no picture and no u-boot.** Two lines in `blitscrt.txt` are marked
VERIFY. MiSTer's u-boot is a fork with exFAT added. The FAT partition may want
`load` or `fatload`, on partition 1 or 2. The file tries all four
combinations, but the serial console removes the guesswork. See `docs/BOOT.md`.

## 9. Making it boot straight there

`bootcore` in `MiSTer.ini` will not do this. Both auto-boot call sites call
`fpga_load_rbf(cfg.bootcore)` with no `cfg` argument. The `.txt` is skipped, no
reboot happens, and the bridges get enabled against a design with nothing
behind them. Menu selection is the only path that triggers the hand-off.

The way to boot straight there is to repoint u-boot. From the serial console
(step 10), once the manual load is known good:

```
=> setenv bootcmd 'load mmc 0:1 ${loadaddr} blitscrt.rbf; fpga load 0 ${loadaddr} ${filesize}'
=> saveenv
```

MiSTer no longer runs at all, and the setting survives power cycles. If
`saveenv` reports that the environment is read-only, that u-boot was built
without writable env and the menu remains the only route.


## 10. Serial console

The micro-B port on the back panel, beside Ethernet.

```
picocom -b 115200 /dev/ttyUSB0
```

Interrupt the countdown for a u-boot prompt. `printenv` gives the real `bootcmd`
and `loadaddr`, `mmc part` gives the FAT partition number. The load can be
driven by hand before committing it to a file:

```
=> load mmc 0:1 ${loadaddr} blitscrt.rbf
=> fpga load 0 ${loadaddr} ${filesize}
```

Do not add `bridge enable`. M1 has no HPS component and nothing sits behind the
bridges.
