#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Set dr_mode = "peripheral" on the HPS OTG controller in a built device tree.
#
# blitscrt.dtb is the stock socfpga_cyclone5_de10_nano.dtb, copied and renamed,
# and that tree leaves dwc2 in host mode. Correct for MiSTer, where the OTG port
# carries the USB hub for keyboards and joysticks -- wrong here, where the port
# has to be a device so a host can enumerate it as a display.
#
# Confirmed on hardware: with the stock tree, /sys/class/udc/ is empty while
# dmesg shows dwc2 enumerating that hub downstream. No UDC means no gadget,
# whatever configfs is told.
#
# Patching the built dtb rather than the kernel source keeps the kernel tree
# stock, so `make world` stays reproducible against an unmodified checkout.
#
# Usage: tools/set_dr_mode.sh build/blitscrt/blitscrt.dtb

set -eu

DTB="${1:?usage: set_dr_mode.sh <dtb>}"

if ! command -v fdtput >/dev/null 2>&1; then
    echo "set_dr_mode: fdtput not found (install device-tree-compiler)" >&2
    exit 1
fi
[ -f "$DTB" ] || { echo "set_dr_mode: $DTB does not exist" >&2; exit 1; }

# On Cyclone V the two controllers are usb@ffb00000 and usb@ffb40000. The OTG
# connector on a DE10-Nano is the second. The soc node has been at both /soc and
# /soc@0 across kernel versions, so try the plausible paths rather than assume.
patched=0
for path in /soc/usb@ffb40000 /soc@0/usb@ffb40000 \
            /soc/usb@ffb00000 /soc@0/usb@ffb00000; do
    fdtget "$DTB" "$path" compatible >/dev/null 2>&1 || continue

    # Only the enabled one. A disabled controller is not the OTG port.
    status=$(fdtget -ts "$DTB" "$path" status 2>/dev/null || echo okay)
    [ "$status" = "okay" ] || continue

    was=$(fdtget -ts "$DTB" "$path" dr_mode 2>/dev/null || echo "<unset>")
    fdtput -t s "$DTB" "$path" dr_mode peripheral
    echo "  $path: dr_mode $was -> peripheral"
    patched=$((patched + 1))
done

if [ "$patched" -eq 0 ]; then
    echo "set_dr_mode: no enabled USB controller found in $DTB." >&2
    echo "  Check the node path with:  fdtdump $DTB | grep -n usb@" >&2
    exit 1
fi

echo "  dr_mode set on $patched controller(s); /sys/class/udc/ should name one"
echo "  after boot. The USB hub add-on must come off that port -- it and the"
echo "  gadget want the same connector."
