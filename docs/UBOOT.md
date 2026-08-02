# The bootloader

`make uboot` builds the preloader and u-boot that go in the card's A2 partition.
This is what it does and why, since almost none of it is obvious and one part is
a patch applied to somebody else's source tree.

For the environment that bootloader runs -- importing it, changing it, recovering
from a bad one -- see `UBOOT_ENV.md`. This file is about the bootloader itself.


## The toolchain

**MiSTer's u-boot needs gcc 4 or 5.** Their wiki says so plainly:

> Building a working u-boot image seems to requires an ARM cross-compilation
> toolchain with GCC version 4 or 5. Warning: In my experience, using a later
> version of GCC produces a u-boot image that is unable to reboot without a
> power cycle.
>
> -- [Compiling the boot loader for MiSTer](https://github.com/MiSTer-devel/Wiki_MiSTer/wiki/Compiling-the-boot-loader-for-MiSTer)

The stock image ships built with gcc 4.8. Built with a 2024 buildroot toolchain
-- gcc 13, eight major versions later -- the SPL hangs at its own banner:

```
U-Boot SPL 2017.03+ (Aug 02 2026 - 01:34:48)
```

and nothing after. Not even `Trying to boot from MMC1`. It looks exactly like a
broken source tree, and is not.

```
make uboot-toolchain      # Linaro 5.5-2017.10, ~100 MB, once
make uboot
```

That fetches **Bootlin's `armv7-eabihf--glibc--stable-2017.05`**, which is gcc
5.4.0 -- inside the range the wiki asks for, and from the same source as the
toolchain the rest of this project uses.

Not Linaro's, which the wiki names. `releases.linaro.org` now redirects every
toolchain URL to a contact page:

```
HTTP request sent, awaiting response... 301 Moved Permanently
Location: https://www.linaro.org/contact/ [following]
```

so those archives are gone, and a download of one silently yields a 57 KB HTML
page. `make uboot-toolchain` checks what it received before unpacking, which is
how that showed up as anything other than a confusing `tar` error.

It also looks in `~/Downloads`, `~` and the current directory first, so a
manually fetched tarball is picked up. Any gcc 4 or 5 ARM toolchain will do --
`UBOOT_CROSS=/path/to/bin/arm-linux-gnueabihf-` overrides the lot.

`UBOOT_CROSS` picks it up automatically if it is there and falls back to the
project's usual `CROSS_COMPILE` otherwise. Nothing else in this project cares:
the kernel and the daemon both build fine with a current compiler.

This cost several hours and a lot of your time. The evidence was in a wiki page
titled "Compiling the boot loader for MiSTer", which is what the forum thread
linking it said it was.


## Why MiSTer's tree and not mainline

Mainline builds cleanly with a modern compiler and boots on this hardware. What
it ships for this board is the **stock DE10-Nano's hardware handoff**, and one
value in it stops this project dead:

| | MiSTer | mainline |
|---|---|---|
| `FPGAPORTRST` | **0x3FFF** | 0x1FF |
| `REG_FILE_INIT_SEQ_SIGNATURE` | 0x555504a0 | 0x555504a1 |
| `S2FUSER1CLK_CNT` | 511 | 19 |
| `S2FUSER2CLK_CNT` | 4 | 5 |

plus IO calibration and pin mux differences.

`FPGAPORTRST` gates the FPGA-to-SDRAM ports. Nine enabled where fourteen are
needed: `rtl/mister/sysmem.sv` wires three f2sdram ports and they land in bits
mainline never enables.

### What that looks like

Everything works except the one thing. The board boots, the fabric is configured,
the test card displays perfectly -- it is generated inside the fabric and never
touches memory. A host enumerates, sets its mode, and streams whole frames that
arrive intact:

```
trace: bulk 648x480 at 0,0, 230026 bytes on the wire, 622080 decompressed
```

622080 is exactly 648 x 480 x 2. The frames reach DDR3. And the screen is black,
because the fabric's reads come back empty:

```
last line   0 beats
underruns   255 (saturated)
```

### It cannot be fixed from Linux

`FPGAPORTRST` is at `0xFFC25080` and looks writable. It is not, usefully: the
port configuration is latched by `APPLYCFG` while the SDRAM interface is idle,
which is the preloader's job at boot. Writing `0x3FFF` there from Linux hangs the
board.

### Using mainline anyway

`uboot/de10-nano-qts/` holds MiSTer's four handoff headers -- BSD-3-Clause
generated output, so they live here -- and `tools/uboot_fix_handoff.py` copies
them into whatever tree is being built, renaming the macro prefix for trees that
expect `CFG_`.

That gets mainline further but was not made to work: with MiSTer's
`FPGAPORTRST`, `bridge enable` in the boot command hangs u-boot at exactly the
point it runs. Left as an unfinished alternative rather than a recommendation.


## `bridge enable`

MiSTer's `include/configs/socfpga_de10_nano.h` defines the environment their
bootloader starts with, and its `fpgaload` is:

```
load mmc 0:$mmc_boot $fpgadata $core; fpga load 0 $fpgadata $filesize;
bridge enable; mw 0x1FFFF000 0; mw 0xFFD05054 0
```

**`bridge enable`** is the u-boot command that takes the HPS-to-FPGA bridges out
of reset. Ours did not issue it, which is what `brgmodrst 0x00000007` was
reporting: all three still held.

It went unnoticed for a long time because it only matters when booting directly.
Coming in through MiSTer's hand-off, MiSTer's own environment had already done it,
and nothing here replaced that environment. Supplying the whole boot command meant
supplying that line too, and it was missing.

Both `tools/uboot_env.txt` and `tools/blitsenv.txt` now issue it.


## Patching the boot command in

The boot command has to be part of the bootloader, not just a file on the card.
A card rewritten from an image has no saved environment -- u-boot on this board
keeps it on the card rather than in flash -- so a bootloader that already knows
what to do is what removes the one-time serial import.

Modern u-boot has `CONFIG_BOOTCOMMAND` as a Kconfig symbol, and
`tools/uboot_config.sh` sets it in `.config`. MiSTer's tree is from 2018 and does
not: it is a `#define` in the board header.

```c
#define CONFIG_BOOTCOMMAND	"mw 0xff709004 0x800; run mmcload; run mmcboot"
```

Setting it in `.config` therefore does nothing. `olddefconfig` drops the unknown
symbol without complaint and the built bootloader keeps MiSTer's own command,
which looks for `menu.rbf` and MiSTer's kernel and finds neither on our card.

So `tools/uboot_patch_header.py` edits the header. **Which** header comes from
`CONFIG_SYS_CONFIG_NAME` in `.config`, which for this build is:

```
CONFIG_SYS_CONFIG_NAME="socfpga_de10_nano"
```

That matters more than it looks. Searching `include/configs/` for the first file
defining `CONFIG_BOOTCOMMAND` finds dozens -- one per board -- and the first
alphabetically is `jupiter.h`. An earlier version did exactly that and patched
`mx25pdk.h`, leaving the header this build actually uses untouched, so the
bootloader kept MiSTer's own boot command and an unrelated board file was quietly
modified.

The patcher itself:

- **is idempotent.** A marker comment records that it has run, so rebuilding does
  not stack edits.
- **keeps the original**, commented, immediately below the replacement, so it is
  clear what was there before.
- **fails loudly** if `CONFIG_BOOTCOMMAND` is not found, rather than silently
  producing a bootloader that boots something else.

`tools/uboot_config.sh` picks the route: Kconfig if the symbol exists, the header
if it does not, and if neither works it says so and carries on. That last case is
not fatal -- the bootloader is fine, the card just needs the environment imported
once, which `UBOOT_ENV.md` covers.


## The dtc version check

`scripts/dtc-version.sh` turns `dtc -v` into a four-digit number:

```sh
MAJOR=$($dtc -v | head -1 | awk '{print $NF}' | cut -d . -f 1)
printf "%02d%02d\n" $MAJOR $MINOR
```

Some dtc builds print `Version: DTC 1.7.0` and some print `Version: DTC v1.7.2`.
On the second, `MAJOR` is `v1`, `printf` refuses it, and the build stops:

```
./scripts/dtc-version.sh: line 20: printf: v1: invalid number
```

A 2018 script meeting a newer dtc. `tools/uboot_fix_dtc.sh` strips the leading
`v`, idempotently and with a marker, the same as the header patch.


## System libfdt

With a distribution's dtc development package installed, the host tools used to
fail with hundreds of lines of:

```
/usr/include/libfdt_env.h:27:30: error: conflicting types for 'fdt64_t'
/usr/include/libfdt.h:2242:19: error: redefinition of 'fdt_appendprop_u32'
```

`tools/Makefile` builds them with:

```make
$(patsubst -I%,-idirafter%, $(filter -I%, $(UBOOTINCLUDE)))
```

which puts u-boot's `include/` **after** the system directories. That is
deliberate and correct: the host tools want `<stdio.h>` and `<malloc.h>` from the
host and only u-boot-specific headers from `include/`. In 2018 it was harmless
for libfdt too, because a build host had none of its own.

Now there is a `/usr/include/libfdt.h`. Any u-boot source asking for
`<libfdt.h>` gets the host's, while the force-included
`./include/libfdt_env.h` is u-boot's -- and the two use different include guards,
`_LIBFDT_ENV_H` against `LIBFDT_ENV_H`, so neither stops the other and every fdt
type is defined twice.

### Two fixes that do not work

Both look like they should, which is why they are recorded.

**Adding `-I$(srctree)/include` alongside.** gcc deduplicates the search path and
keeps the *later* entry. It says so if asked:

```
$ cc -I./include -idirafterinclude ... -v
ignoring duplicate directory "./include"
#include <...> search starts here:
 /usr/include
 include            <- still last
```

**Taking `include/` out of the `-idirafter` list** so it is a plain `-I`. This
fixes libfdt and immediately breaks everything else, because `<malloc.h>` then
finds u-boot's instead of the host's.

### What does work

Change the includes rather than the search order.
`tools/uboot_fix_libfdt.py` rewrites every reference to those three headers --
`libfdt.h`, `libfdt_env.h`, `fdt.h` -- into a path relative to the file doing the
including. A relative include resolves before any `-I` or `-idirafter` directory
and cannot be reordered out from under it.

43 includes across 21 files, all under `include/`, `lib/` and `tools/`, which are
the paths that end up in host tools. Cross-compiled sources keep u-boot's own
flags and never see the host's headers, so they are untouched.

Two subtleties, both of which cost a build to find:

- **Quoted includes need it too**, when the header is in another directory.
  `lib/fdtdec_common.c` had `#include "libfdt.h"` and there is no `libfdt.h` in
  `lib/`, so the quote found nothing locally and fell through to the same search
  path.
- **Angle includes need it even when the header is adjacent.** Angle brackets
  never search the including file's own directory, so `include/libfdt.h` asking
  for `<libfdt_env.h>` could still get the host's.

Verified: `make tools-only` builds `mkimage` and the rest on a host with
`libfdt-dev` installed.


## Toolchains and -march

Worth knowing if the ARM half fails with:

```
arm-linux-gnueabihf-gcc: error: unrecognized -march target: armv5
```

`arch/arm/Makefile` picks the architecture with a `cc-option` probe:

```make
arch-$(CONFIG_CPU_V7) = $(call cc-option, -march=armv7-a, \
                        $(call cc-option, -march=armv7, -march=armv5))
```

On a hard-float toolchain the probe fails -- `-march=armv7-a` alone does not
imply an FPU, and the compiler's default `-mfloat-abi=hard` then has nothing to
use -- so it falls through to `armv5`, which a modern gcc also rejects.

A buildroot `armv7-eabihf` toolchain of the kind `make get-toolchain` fetches
does not hit this. A distribution's `gcc-arm-linux-gnueabihf` may.


## Host requirements

u-boot's Kconfig is generated, so the build needs `bison`, `flex` and `bc` on the
build host. None of the rest of this project uses them, and without them u-boot
fails deep inside its own Makefile with no hint that a package is missing --
so `make uboot` checks first, and `make setup` installs them.

`make tools` reports them alongside everything else.


## What it produces

`u-boot-with-spl.sfp`: the preloader and u-boot in one file, which is exactly what
the A2 partition holds. `make image` picks it up automatically.

23 files in the u-boot tree are modified, all marked `blitsCRT` and all
idempotent:

```
include/configs/socfpga_de10_nano.h    the boot command
scripts/dtc-version.sh                 the version parse
21 under include/, lib/, tools/        the fdt include paths
```

`git status` in `$(UBOOT_DIR)` should show those and nothing else. Anything more
means a patcher matched something it should not have.


## The fallback: don't build it at all

`make uboot` works, and is what `make world` uses. This route exists for when it
does not -- a distribution whose compilers or headers break the build in some new
way:

```
tools/make_image.sh --extract-boot /dev/sdX boot.a2
make image BOOT_A2=boot.a2
```

One command, against a card you already have. It uses MiSTer's own preloader
binary, so it cannot break when a distribution updates its dtc. The cost is that
the blob is not yours to redistribute and it needs a MiSTer card to extract from,
which is exactly why `make uboot` is the default.


## What this cost

Building a 2018 tree on a modern host needed three source patches -- the dtc
version format, the boot command's location, and the libfdt include paths -- and
a toolchain eight major versions older than the one everything else uses.

Almost none of that was predictable, and two attempts at the libfdt problem
looked right and were not. What settled it each time was reading the source and
asking `gcc -v` what it was actually doing, rather than reasoning about what
ought to work. A fourth incompatibility on a different distribution would not be
surprising, which is why the fallback above is kept.

Keep a working MiSTer card while changing any of this. There is no JTAG on a
MiSTer Pi, and a card that will not boot has no serial output to interrupt -- a
known-good card is the only way back.
