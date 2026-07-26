#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# gud-probe.sh -- work out what the running kernel can do for a USB gadget.
#
# GUD needs the MiSTer HPS to act as a USB *device* (peripheral), which needs a
# USB Device Controller (UDC), the dwc2 controller in peripheral/dual-role mode,
# and FunctionFS. This dumps everything relevant so we can tell whether the stock
# kernel can do it, needs only a device-tree/mode change, or needs a rebuild.
#
# Run on the board: sh /media/fat/linux/gud-probe.sh
# Copy the whole output back.

echo "===== blitsCRT GUD capability probe ====="
echo "date: $(date 2>/dev/null)"
echo "kernel: $(uname -a)"
echo ""

echo "----- 1. UDC present? (the key question) -----"
if [ -d /sys/class/udc ] && [ -n "$(ls -A /sys/class/udc 2>/dev/null)" ]; then
    echo "UDC(s): $(ls /sys/class/udc)"
    echo "  -> hardware CAN be a USB device. Good."
else
    echo "no UDC registered. Cannot be a USB device in the current state."
fi
echo ""

echo "----- 2. kernel config: is gadget support even built? -----"
if [ -f /proc/config.gz ] && command -v zcat >/dev/null 2>&1; then
    zcat /proc/config.gz | grep -iE \
      'CONFIG_USB_GADGET|CONFIG_USB_DWC2|CONFIG_USB_CONFIGFS|CONFIG_USB_FUNCTIONFS|CONFIG_USB_LIBCOMPOSITE' \
      || echo "  (none of the gadget symbols found)"
else
    echo "no /proc/config.gz (kernel built without IKCONFIG). Cannot read config"
    echo "directly; will infer from modules and dmesg below."
fi
echo ""

echo "----- 3. how is dwc2 configured? -----"
dmesg 2>/dev/null | grep -i dwc2 | head -20 || echo "  (no dwc2 lines in dmesg)"
echo "dr_mode files:"
for f in /sys/bus/platform/drivers/dwc2/*/dr_mode; do
    [ -f "$f" ] && echo "  $f = $(cat "$f")"
done 2>/dev/null
echo ""

echo "----- 4. is the gadget stack loadable? -----"
echo "configfs mount:"
mount 2>/dev/null | grep -i configfs || echo "  configfs not mounted"
ls /sys/kernel/config/ 2>/dev/null || echo "  /sys/kernel/config not present"
echo "trying to load libcomposite:"
modprobe libcomposite 2>&1 || echo "  modprobe libcomposite failed (may be built-in or absent)"
ls /sys/kernel/config/usb_gadget/ 2>/dev/null \
  && echo "  -> usb_gadget configfs dir EXISTS: gadget framework is usable" \
  || echo "  -> no usb_gadget configfs dir"
echo ""

echo "----- 5. available usb modules -----"
find /lib/modules/$(uname -r) -name '*.ko*' 2>/dev/null | grep -iE 'dwc2|libcomposite|usb_f_fs|configfs' \
  || echo "  (no matching modules found under /lib/modules)"
echo ""

echo "----- 6. functionfs / gadget in /proc -----"
grep -i functionfs /proc/filesystems 2>/dev/null || echo "  functionfs not in /proc/filesystems"
echo ""
echo "===== end probe ====="
