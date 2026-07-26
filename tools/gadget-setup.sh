#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Create the USB gadget over configfs and mount FunctionFS for blitscrtd.
#
# Run once at boot, before blitscrtd. Requires the dwc2 controller in
# peripheral mode, which comes from dr_mode = "peripheral" in the device tree.
#
# The MiSTer Pi fits a Type-A host receptacle where the DE10-Nano has micro-AB,
# so the cable needs VBUS cut on the board side.

set -eu

G=/sys/kernel/config/usb_gadget/blitscrt
FFS=/dev/ffs-blitscrt

modprobe libcomposite 2>/dev/null || true
mountpoint -q /sys/kernel/config || mount -t configfs none /sys/kernel/config

if [ -d "$G" ]; then
    echo "gadget already exists, tearing down"
    echo "" > "$G/UDC" 2>/dev/null || true
fi

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

echo "gadget staged. start blitscrtd, then bind:"
echo "  ls /sys/class/udc"
echo "  echo <udc-name> > $G/UDC"
