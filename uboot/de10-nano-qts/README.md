# The hardware handoff

Four generated headers from MiSTer's Platform Designer project, taken from
`MiSTer-devel/u-boot_MiSTer` at `board/terasic/de10-nano/qts/`.

**BSD-3-Clause**, as the SPDX line in each says. They are generated output
describing how the hardware is wired, not anyone's hand-written source, which is
why they can live here.

## Why they are needed

The preloader configures DDR3, the PLLs, the pin mux and the FPGA-to-SDRAM ports
from these. Those settings are latched by `APPLYCFG` while the SDRAM interface is
idle -- the preloader's job at boot, and impossible from Linux afterwards.

Mainline u-boot ships the stock DE10-Nano's versions. One value differs in a way
that stops this project dead:

| | MiSTer | mainline |
|---|---|---|
| `FPGAPORTRST` | **0x3FFF** | 0x1FF |
| `REG_FILE_INIT_SEQ_SIGNATURE` | 0x555504a0 | 0x555504a1 |
| `S2FUSER1CLK_CNT` | 511 | 19 |
| `S2FUSER2CLK_CNT` | 4 | 5 |

plus IO calibration and pin mux differences.

`FPGAPORTRST` is the one that matters. Nine ports enabled where fourteen are
needed: `rtl/mister/sysmem.sv` wires three f2sdram ports and they land in bits
mainline never enables. The symptom is a board that boots perfectly, shows its
test card, accepts whole frames from a host over USB into DDR3 -- and displays
nothing, because the fabric's reads come back empty:

```
last line   0 beats
underruns   255 (saturated)
```

Writing the register at runtime does not work. It hangs the board: the value has
to be latched before the SDRAM controller is running.

## Keeping them current

`tools/uboot_fix_handoff.py` copies these into a u-boot tree, renaming the macro
prefix from `CONFIG_` to `CFG_` if that tree expects the newer spelling.

To refresh them, take the four files again from `u-boot_MiSTer` and copy them
here unmodified -- the prefix rename happens on the way into the build tree, not
here.
