# Getting the bitstream onto the board

The MiSTer Pi has no onboard USB-Blaster. The SD card is the only route in.
There are three ways to take it, with different risk.

## The mechanism MiSTer already has

`fpga_load_rbf()` in `Main_MiSTer/fpga_io.cpp` does this before anything else:

```c
if (cfg)
{
    fpga_core_reset(1);
    make_env(name, cfg);
    do_bridge(0);
    reboot(0);
}
```

`cfg` is set when a `.rbf` has a `.txt` alongside it with the same stem.
`make_env()` maps physical `0x1FFFF000`, writes the magic bytes
`21 43 65 87`, then `core="<name>"`, then the whole contents of the `.txt`.
Then it drops the bridges and reboots. u-boot finds that block on the way back
up and runs those commands instead of its own.

MiSTer's Desktop Linux uses this to boot a different kernel. It is a supported
hook. For blitsCRT_Mister it means the bootloader configures the FPGA and Linux never
starts.

So the install is two files in the FAT partition root:

```
blitscrt.rbf
blitscrt.txt
```

Select `blitscrt.rbf` in the MiSTer menu. It reboots once, u-boot configures the
FPGA, the test card appears, nothing else runs. Power cycle to get MiSTer back.

## Why not just load it as a core

Without a `.txt`, MiSTer takes the other path and programs the FPGA directly.
The last thing it does on success is:

```c
do_bridge(1);
```

That enables the HPS-to-FPGA bridges. M1 has no HPS component in the fabric, so
there is no slave behind the lightweight bridge. MiSTer then calls
`fpga_core_id()`, which reads the GPI register through that bridge looking for
the magic `0x5CA623`. An AXI read with nothing to answer it does not return.

The FPGA stays configured either way. Configuration does not depend on the ARM
staying alive. The picture should still come up. Expect to power cycle. A hang
here is the bridge.

The `.txt` path avoids this entirely, because `do_bridge(0)` runs and the reboot
happens before any of that code is reached.

## Verify the override before trusting it

Two lines in `quartus/output_files/blitscrt.txt` are marked VERIFY. MiSTer's u-boot is a fork
with exFAT support added, and I have not been able to confirm from source
whether its FAT partition wants `load` or `fatload`, or what it calls its own
boot variables.

The back panel has a UART micro-B port. That is a serial console, and it is the
fastest way to settle this:

```
picocom -b 115200 /dev/ttyUSB0
```

Interrupt the countdown, then:

```
=> printenv
=> mmc part
```

`printenv` gives you the real `bootcmd` and `loadaddr`. `mmc part` confirms
which partition number the FAT lives on. Fill those into `blitscrt.txt` and the
guesswork is gone.

You can also test the whole sequence by hand at the u-boot prompt before
committing it to a file:

```
=> load mmc 0:1 ${loadaddr} blitscrt.rbf
=> fpga load 0 ${loadaddr} ${filesize}
```

If the test card appears, those two lines are correct and the `.txt` will work.

## Load address

`make_env()` uses physical `0x1FFFF000` for the environment block. Do not load
the bitstream near it. `0x2000000` is 32 MB into DDR3 and well clear. Whatever
`printenv` reports for `loadaddr` is almost certainly fine.

## Booting our own Linux, from M2

The `.txt` carries u-boot commands. M1 uses two of them; there is room for a
full kernel boot. MiSTer's Desktop Linux works this way.

```
bootdelay=2
loadaddr=0x2000000
kernaddr=0x1000000
dtbaddr=0x1800000

loadrbf=load mmc 0:1 ${loadaddr} blitscrt.rbf
progfpga=fpga load 0 ${loadaddr} ${filesize}
loadkern=load mmc 0:1 ${kernaddr} blitscrt/zImage
loaddtb=load mmc 0:1 ${dtbaddr} blitscrt/blitscrt.dtb
bootargs=console=ttyS0,115200 quiet

bootcmd=run loadrbf; run progfpga; bridge enable; run loadkern; run loaddtb; bootz ${kernaddr} - ${dtbaddr}
```

`bridge enable` is correct from M2, once the design has an HPS component with
slaves behind the bridges. M1 has nothing there. Its script leaves the command
out for that reason.

The kernel and device tree are ours from this point. MiSTer's are used for its
own first-stage boot and nothing else. That separation is what makes M4 work:
`dr_mode = "peripheral"` goes in our dtb while MiSTer keeps host mode for its
controllers, and the warm reboot switches between them.

### Rootfs shape

Bake an initramfs into `zImage` and M2 through M4 still only ever add files to
the FAT partition. No third partition, no repartitioning, the MiSTer install
untouched. The whole device becomes four files sitting next to `menu.rbf`:

```
blitscrt.rbf
blitscrt.txt
blitscrt/zImage        kernel with embedded initramfs
blitscrt/blitscrt.dtb  device tree
```

Busybox plus the gadget daemon is a small initramfs, and the device has one
job. The alternative is a loop-mounted image on FAT, which is what MiSTer does
with `linux.img`.

### What it costs

Two full boots on every power-on: MiSTer's stack, a menu selection, the warm
reboot, then ours. Roughly 30 to 40 seconds to picture, and the selection is
manual.

`bootcore` cannot automate it. `fpga_load_rbf(cfg.bootcore)` passes no `cfg`,
so the `.txt` is skipped and the hand-off never fires. Unattended boot means
repointing u-boot with `saveenv`, which drops MiSTer from the picture
altogether -- see `UBOOT_ENV.md` for that procedure.

## The standalone card

Done. `make uboot` builds a bootloader and `make image` produces a card image
that boots BlitsCRT directly, with no MiSTer on the card at all. See `UBOOT.md`
for the bootloader and the README for the image.

The layout ended up as:

- Partition 1 FAT32 with the bitstream, kernel and daemon
- Partition 2 type `a2`, holding SPL and u-boot as raw sectors

FAT is numbered first because `bootcmd` addresses it as `mmc 0:1`, the same as a
MiSTer card. The A2 partition still sits first on disk; table order and disk order
are independent, and the BootROM scans for the type rather than the number. There
is no ext4 rootfs: the root filesystem is an initramfs inside the kernel image.

This section used to predict where the trouble would be, and it is worth recording
what it got right and wrong. The suspicion was the preloader's **DDR3 timings** --
a clone board need not populate the same memory parts as a DE10-Nano. That turned
out fine: mainline's preloader brings up DRAM on a MiSTer Pi without complaint.

What actually bit was the rest of the same sentence, the **Platform Designer
handoff**, and a missing `bridge enable` in our own boot command. `UBOOT.md` has
both.
