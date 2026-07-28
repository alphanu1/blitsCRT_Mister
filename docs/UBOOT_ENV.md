# The u-boot environment

`tools/blitsenv.txt` holds the boot configuration: which bitstream to load, where
the kernel and device tree live, and the kernel command line. It reaches u-boot
one of two ways.

**Through MiSTer**, as `blitscrt.txt` beside `blitscrt.rbf` on the card. MiSTer's
`fpga_load_rbf()` copies it into the magic block at `0x1FFFF000` and warm-reboots,
and u-boot runs those commands instead of its own. Nothing is written to flash.
That is the arrangement described in `BOOT.md`, and it needs a MiSTer menu
selection on every power-on.

**Directly**, by importing the file into u-boot's saved environment. Unattended,
survives power cycles, and drops MiSTer from the picture altogether. This is that
procedure.

## Importing

Copy `tools/blitsenv.txt` to the root of the card's FAT partition, then interrupt
u-boot on the serial console and:

```
mmc rescan
fatload mmc 0:1 0x02000000 blitsenv.txt
env import -t 0x02000000 ${filesize}
env print
saveenv
boot
```

`-t` reads the file as text rather than a binary blob. `${filesize}` is set by
`fatload`, so the length is right without counting bytes -- getting it wrong
truncates the last variable silently.

`env print` before `saveenv` is worth the extra line. It shows `core` and
`bootcmd` as imported, so a truncated read or a typo is visible before anything
is committed to flash.

`0:1` is the first partition on the first MMC device. If the card is laid out
differently, `mmc part` lists them.

## What is in it

```
core=blitscrt.rbf
bootcmd=mw 0xff709004 0x800; mmc rescan; run fpgaload; ...
```

`core` is what `fpgaload` loads -- that variable comes from MiSTer's own
environment and is left alone. `bootcmd` releases the bridges, loads the kernel
and device tree from `blitscrt/` on the FAT partition, sets the command line, and
boots.

The command line carries three things that matter:

- `console=ttyS0,115200` -- the HPS UART, where init and the daemon report
- `loglevel=4` -- warnings and above only. Without it kernel messages drown the
  shell on the same port, which matters during bring-up
- `mem=992M` -- reserves the top 32 MB at `0x3E000000` for scanout. The fabric
  reads that window over f2sdram; Linux must not also be using it

`initcall_blacklist=fb_driver_init` keeps the stock framebuffer driver from
claiming the display.

## Recovery

`blitscrt.nogadget` appended to the `bootargs` line skips USB gadget staging and
boots as before M4: fabric, daemon, shell. Useful if a change to the gadget path
ever wedges the boot, since the way out is then a text edit and a re-import rather
than a kernel rebuild. Needs kernel k6 or later; older kernels ignore it.

To go back to MiSTer entirely, `env default -a` then `saveenv` restores u-boot's
built-in environment.

## Editing on the board

The whole environment can also be set by hand, which is quicker for a one-off:

```
setenv bootargs 'console=ttyS0,115200 loglevel=4 mem=992M blitscrt.nogadget'
boot
```

Without `saveenv` that lasts exactly one boot, which is usually what a recovery
attempt wants. Note the single quotes: u-boot's shell splits on semicolons, so a
`bootcmd` set without them keeps only the first command.
