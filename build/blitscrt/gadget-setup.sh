#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Create the USB gadget over configfs and mount FunctionFS for blitscrtd.
#
# Run once at boot, before blitscrtd. Requires the dwc2 controller in peripheral
# mode: tools/set_dr_mode.py patches the built dtb for that, and the USB hub
# add-on has to come off the OTG port, since it and the gadget want the same
# connector. On a MiSTer Pi the OTG is a Type-A receptacle, so the cable is A-to-A
# with VBUS cut on the board side -- both ends look like hosts. The micro-USB on
# an assembled unit belongs to the hub add-on and is that hub's upstream input,
# not this port.
#
# This only stages the gadget. blitscrtd binds it to the UDC once it has written
# the descriptors to ep0 -- binding before that would offer a host a device with
# no endpoints behind it.

set -eu

G=/sys/kernel/config/usb_gadget/blitscrt
FFS=/dev/ffs-blitscrt

modprobe libcomposite 2>/dev/null || true
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

# Unwind any previous gadget, in reverse order of construction.
#
# Unbinding the UDC is not enough on its own. The FunctionFS instance name stays
# claimed while the mount is up, so a later mkdir of functions/ffs.blitscrt fails
# with EBUSY -- which is what a half-torn-down gadget looks like, and it is not
# obvious from the error what is holding it. Every step tolerates being already
# gone, so this is safe to run on a clean system too.
teardown() {
    # The mount is dealt with first and unconditionally. It can outlive the
    # gadget directory -- remove the configfs tree while functionfs is still
    # mounted and the instance name stays claimed, so the next
    # mkdir functions/ffs.blitscrt returns EBUSY with no gadget in sight to
    # explain it. Gating this on $G existing was exactly that mistake.
    if grep -q " $FFS " /proc/mounts 2>/dev/null; then
        echo "unmounting stale $FFS"
        umount "$FFS" 2>/dev/null || {
            echo "  cannot unmount $FFS -- is blitscrtd still running?" >&2
            echo "  stop it first:  killall blitscrtd" >&2
            exit 1
        }
    fi

    [ -d "$G" ] || return 0
    echo "tearing down the previous gadget"

    printf '' > "$G/UDC" 2>/dev/null || true      # detach from the controller

    rm -f  "$G/configs/c.1/ffs.blitscrt"           2>/dev/null || true
    rmdir  "$G/configs/c.1/strings/0x409"          2>/dev/null || true
    rmdir  "$G/configs/c.1"                        2>/dev/null || true
    rmdir  "$G/functions/ffs.blitscrt"             2>/dev/null || true
    rmdir  "$G/strings/0x409"                      2>/dev/null || true
    rmdir  "$G"                                    2>/dev/null || true
}

teardown

mkdir -p "$G"
cd "$G"

# GUD's host driver matches on VID:PID. 1d50:614d is the Openmoko-donated pair
# the protocol uses; the kernel driver already binds it.
echo 0x1d50 > idVendor
echo 0x614d > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "blitsCRT"        > strings/0x409/manufacturer
echo "blitsCRT_Mister" > strings/0x409/product
echo "0001"            > strings/0x409/serialnumber

mkdir -p configs/c.1/strings/0x409
echo "GUD display" > configs/c.1/strings/0x409/configuration
echo 250           > configs/c.1/MaxPower

mkdir -p functions/ffs.blitscrt
ln -sf functions/ffs.blitscrt configs/c.1/

mkdir -p "$FFS"
mountpoint -q "$FFS" || mount -t functionfs blitscrt "$FFS"

if [ ! -d /sys/class/udc ] || [ -z "$(ls -A /sys/class/udc 2>/dev/null)" ]; then
    echo ""
    echo "WARNING: /sys/class/udc is empty -- no gadget controller."
    echo "  dwc2 is still in host mode. The dtb needs dr_mode = peripheral;"
    echo "  see tools/set_dr_mode.py. Nothing will enumerate until then."
fi

echo "gadget staged at $G, FunctionFS at $FFS."
echo "blitscrtd binds the UDC itself once its descriptors are in."
