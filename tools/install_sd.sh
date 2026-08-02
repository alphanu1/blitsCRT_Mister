#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copy the bitstream and its u-boot override onto a mounted MiSTer SD card.
#
#   ./tools/install_sd.sh /run/media/you/MiSTer
#
# Only two files are added. Everything else the card needs is the existing
# MiSTer install: the A2 partition holding the preloader and u-boot, and the
# userland that reads the .txt and triggers the reboot.

set -eu

DEST="${1:-}"
RBF="quartus/output_files/blitscrt.rbf"
TXT="quartus/output_files/blitscrt.txt"

if [ -z "$DEST" ]; then
    echo "usage: $0 /path/to/mounted/sd" >&2
    exit 1
fi

if [ ! -d "$DEST" ]; then
    echo "$DEST is not a directory" >&2
    exit 1
fi

if [ ! -f "$RBF" ]; then
    echo "no bitstream at $RBF" >&2
    echo "run 'make bitstream' first" >&2
    exit 1
fi

# The kernel and device tree, staged by 'make world' when a kernel tree is set.
KDIR="build/blitscrt"

# generated next to the bitstream so the .rbf name inside it always matches. If a
# custom kernel is staged (M2+), regenerate it to boot that kernel on the warm
# reboot; otherwise it halts after configuring the FPGA (M1).
if [ -f "$KDIR/zImage" ]; then
    echo "kernel staged -- generating $TXT to boot it" >&2
    python3 tools/gen_uboot_txt.py "$TXT" --linux >&2
elif [ ! -f "$TXT" ]; then
    echo "generating $TXT (halts after FPGA; no kernel staged)" >&2
    python3 tools/gen_uboot_txt.py "$TXT" >&2
fi

# --- is this actually a MiSTer card? ---
#
# Only worth asking when staging onto a card that boots MiSTer, where the
# hand-off through blitscrt.txt is what gets us into u-boot. A standalone card
# boots u-boot directly and has no MiSTer on it by design, so the question is
# noise -- and it is asked interactively, which stops a build dead.
#
# BLITSCRT_STANDALONE=1 says so. `make image` sets it.
missing=""
if [ "${BLITSCRT_STANDALONE:-0}" != "1" ]; then
    [ -f "$DEST/menu.rbf" ] || missing="$missing menu.rbf"
    [ -f "$DEST/MiSTer" ]   || missing="$missing MiSTer"
    [ -d "$DEST/linux" ]    || missing="$missing linux/"
fi

if [ -n "$missing" ]; then
    echo "WARNING: $DEST is missing:$missing" >&2
    echo "" >&2
    echo "The hand-off needs a working MiSTer install. MiSTer's own userland is" >&2
    echo "what reads blitscrt.txt and reboots into u-boot. Without it these two" >&2
    echo "files do nothing." >&2
    echo "" >&2
    printf "Continue anyway? [y/N] " >&2
    read -r reply
    case "$reply" in [Yy]*) ;; *) echo "aborted" >&2; exit 1 ;; esac
fi

# --- other .txt files trigger a picker instead of auto-selecting ---
# menu.cpp counts every .txt in the directory. Exactly one, named to match the
# .rbf, is taken automatically. More than one and MiSTer asks which to use.
others=0
[ "${BLITSCRT_STANDALONE:-0}" = "1" ] || \
    others=$(find "$DEST" -maxdepth 1 -iname '*.txt' ! -iname 'blitscrt.txt' 2>/dev/null | wc -l)
if [ "$others" -gt 0 ]; then
    echo "NOTE: $others other .txt file(s) in the card root."
    echo "      MiSTer will show a picker rather than taking blitscrt.txt"
    echo "      automatically. Choose blitscrt.txt from the list."
    echo ""
fi

cp -v "$RBF"             "$DEST/blitscrt.rbf"
cp -v "$TXT"             "$DEST/blitscrt.txt"

# M2+: the kernel and device tree ride under blitscrt/ on the card, exactly where
# blitscrt.txt's loadkern/loaddtb look for them. The initramfs is embedded inside
# zImage, so these two files are the whole rootfs -- nothing else to copy.
if [ -f "$KDIR/zImage" ]; then
    mkdir -p "$DEST/blitscrt"
    cp -v "$KDIR/zImage" "$DEST/blitscrt/zImage"
    [ -f "$KDIR/blitscrt.dtb" ] && cp -v "$KDIR/blitscrt.dtb" "$DEST/blitscrt/blitscrt.dtb"
    # blitscrtd is baked into the initramfs too, but a copy here is the one init
    # prefers, so the daemon can be swapped without rebuilding the kernel. The
    # gadget scripts ride along for M4.
    [ -f "$KDIR/blitscrtd" ]            && cp -v "$KDIR/blitscrtd"            "$DEST/blitscrt/blitscrtd"
    [ -f "$KDIR/blitscrt-peek" ]        && cp -v "$KDIR/blitscrt-peek"        "$DEST/blitscrt/blitscrt-peek"
    [ -f "$KDIR/blitscrt-ddrbench" ]    && cp -v "$KDIR/blitscrt-ddrbench"    "$DEST/blitscrt/blitscrt-ddrbench"
    [ -f "$KDIR/gadget-setup.sh" ]      && cp -v "$KDIR/gadget-setup.sh"      "$DEST/blitscrt/gadget-setup.sh"
    [ -f "$KDIR/find-io.sh" ]           && cp -v "$KDIR/find-io.sh"           "$DEST/blitscrt/find-io.sh"
    echo "kernel + device tree copied under blitscrt/"
fi
sync

echo ""
if [ "${BLITSCRT_STANDALONE:-0}" = "1" ]; then
    # A card that boots u-boot directly. Nothing here selects a core from a
    # menu, and there is no MiSTer to return to.
    echo "  Staged for a standalone card. It boots straight into BlitsCRT --"
    echo "  no MiSTer, no menu, no hand-off."
    echo ""
    echo "  Watch the boot on the serial console at 115200, or read"
    echo "  blitscrt-boot.log on the card afterwards."
else
    echo "  Boot the MiSTer and select blitscrt.rbf from the menu."
    echo "  It reboots once, then configures the FPGA (test card)."
    if [ -f "$KDIR/zImage" ]; then
        echo "  Our kernel then boots and appends a record to"
        echo "  /media/fat/blitscrt-boot.log -- power-cycle and read that file"
        echo "  (or watch the boot on the serial console at 115200) to confirm."
    else
        echo "  Power cycle to return to MiSTer."
    fi
    echo ""
    echo "  Note: this works from the SD card only. MiSTer disables the hand-off"
    echo "  for cores on USB storage."
fi
