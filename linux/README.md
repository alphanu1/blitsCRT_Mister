# Linux side

What the HPS runs to bring the device up. Three pieces: a device tree overlay,
a kernel config fragment, and the runtime setup.

## Boot order

1. u-boot loads the `.rbf` (see `../docs/BOOT.md`). The fabric comes up, drives
   the test card, and waits.
2. Linux boots off the SD card.
3. `tools/gadget-setup.sh` runs once, creating the USB gadget over configfs and
   mounting FunctionFS.
4. `blitscrtd` starts, opens the fabric through `/dev/mem`, opens FunctionFS,
   and binds the gadget to the UDC.
5. A host PC sees a GUD display and enumerates it. No driver install; the GUD
   driver has been in-tree since Linux 5.13.

## The two transports

The daemon reaches the fabric one of two ways, matching the `BRIDGE` parameter
in the RTL:

- **GP** (default). The h2f general-purpose port, through `/dev/mem`. This is
  MiSTer's interface and needs nothing in the device tree.
- **LWH2F**. The lightweight bridge at `0xFF200000`. Set `BLITSCRT_LWH2F=1` in
  the daemon's environment. `blitscrt.dts` describes the window.

Switching transports is the RTL `BRIDGE` parameter and this one environment
variable. Nothing else changes.

## Files

- `blitscrt.dts` — device tree overlay. Only needed for the LWH2F path.
- `blitscrt_gadget.config` — kernel options beyond a stock MiSTer/DE10 config,
  mostly the FunctionFS pieces.
- `../tools/gadget-setup.sh` — creates the gadget and mounts FunctionFS.

## The cable

The MiSTer Pi fits a Type-A host receptacle where the DE10-Nano has micro-AB.
The link to the host PC is A-to-A with VBUS cut on the board side, since both
ends are powered.
