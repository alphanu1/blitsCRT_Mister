#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build a complete, writable SD card image.
#
# The output is a .img to be written with dd or Etcher. It needs no root: the
# FAT filesystem is built with mtools rather than by loop-mounting, which also
# means this runs unchanged in CI.
#
# The one part that cannot be generated is the A2 partition. Cyclone V's BootROM
# looks for a raw partition of type 0xA2 holding the preloader and u-boot; it is
# not a file and not in any filesystem. The preloader carries DDR3 timings and
# pin mux from a Platform Designer handoff, and MiSTer's demonstrably works on
# this hardware where one built from mainline may not, since a clone board need
# not populate the same memory parts.
#
# So it is lifted from a MiSTer card or image and everything else is built
# fresh. Extract it once:
#
#   tools/make_image.sh --extract-boot /dev/sdX boot.a2
#
# and keep the blob. Then `make image BOOT_A2=boot.a2` needs nothing else.
#
# Note the blob contains MiSTer's u-boot, which is GPL-2.0. An image built with
# it can be passed around on the same terms -- with an offer of source -- but it
# is not this project's code to relicense.

set -euo pipefail

die() { echo "make_image: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# --extract-boot: pull the A2 partition out of a card or image and stop.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--extract-boot" ]; then
    SRC="${2:-}"; OUT="${3:-}"
    [ -n "$SRC" ] && [ -n "$OUT" ] || die "usage: $0 --extract-boot <card-or-image> <out.a2>"
    [ -e "$SRC" ] || die "$SRC does not exist"
    command -v sfdisk >/dev/null || die "sfdisk not found (util-linux)"

    # Everything from sector 1 up to the first filesystem, not just the A2
    # partition.
    #
    # A2 holds the preloader and u-boot. The u-boot *environment* -- our bootcmd
    # -- is a separate thing, and where it lives depends on how u-boot was
    # configured: QSPI flash if the board has any, otherwise a raw offset on the
    # card, usually in the gap between the partition table and the first
    # partition. Taking the whole slab covers both cases without having to know
    # which, and means an image built from an already-configured card boots
    # straight into BlitsCRT with no import.
    #
    # Sector 0, the partition table, is deliberately left out: the image builds
    # its own, sized for the image rather than for the source card.
    read -r A2_START A2_SIZE FS_START < <(sfdisk -J "$SRC" 2>/dev/null | python3 -c '
import json, sys
try:
    t = json.load(sys.stdin)["partitiontable"]
except Exception:
    sys.exit(1)
parts = t.get("partitions", [])
a2 = [p for p in parts if str(p.get("type", "")).lower() == "a2"]
if not a2:
    sys.exit(1)
# the first partition that is not A2 -- where the slab has to stop
others = [p["start"] for p in parts if str(p.get("type","")).lower() != "a2"]
fs = min(others) if others else a2[0]["start"] + a2[0]["size"]
print(a2[0]["start"], a2[0]["size"], fs)
') || die "no partition of type a2 in $SRC -- is it a MiSTer card or image?"

    [ "$FS_START" -gt "$A2_START" ] || die "the A2 partition is not before the filesystem; this needs looking at by hand"

    SLAB=$(( FS_START - 1 ))
    dd if="$SRC" of="$OUT" bs=512 skip=1 count="$SLAB" status=none

    # Record where the A2 partition sat, so writing it back reproduces the same
    # absolute sectors -- anything stored at a raw offset depends on that.
    printf 'a2_start=%s\na2_size=%s\nslab=%s\n' "$A2_START" "$A2_SIZE" "$SLAB" \
        > "$OUT.layout"

    echo "extracted sectors 1..$FS_START ($((SLAB / 2048)) MB) -> $OUT"
    echo "  A2 partition at sector $A2_START, $((A2_SIZE / 2048)) MB"
    echo "  layout written to $OUT.layout"
    echo
    echo "Keep both. This is the only part of a card that cannot be rebuilt, and"
    echo "if the source card already had the u-boot environment imported, the"
    echo "slab carries it -- an image built from this boots BlitsCRT directly."
    exit 0
fi

# ---------------------------------------------------------------------------
# Build the image.
# ---------------------------------------------------------------------------
BOOT_A2="${BOOT_A2:-}"
OUT="${OUT:-blitscrt.img}"
STAGE="${STAGE:-}"
FAT_MB="${FAT_MB:-256}"

[ -n "$BOOT_A2" ] || die "BOOT_A2 is not set. Extract it once with:
    tools/make_image.sh --extract-boot /dev/sdX boot.a2
  then:
    make image BOOT_A2=boot.a2"
[ -s "$BOOT_A2" ] || die "$BOOT_A2 is missing or empty"
[ -n "$STAGE" ] && [ -d "$STAGE" ] || die "STAGE must be a directory of files for the FAT partition"

for t in sfdisk mformat mcopy mmd truncate; do
    command -v "$t" >/dev/null || die "$t not found (util-linux, mtools)"
done

# The slab is written at sector 1, so everything in it lands where it did on the
# source card. The A2 partition's position comes from the .layout file written by
# --extract-boot; without one, assume the whole slab is the A2 partition starting
# at the conventional 2048.
SLAB_SECTORS=$(( $(stat -c%s "$BOOT_A2") / 512 ))
if [ -f "$BOOT_A2.layout" ]; then
    . "$BOOT_A2.layout"
    A2_AT="$a2_start"
    A2_SECTORS="$a2_size"
else
    # No layout file. Either a u-boot-with-spl.sfp built from source, or an
    # older blob. Both are just the A2 partition's contents, so put them at the
    # conventional 2048.
    case "$BOOT_A2" in
    *.sfp)
        echo "  bootloader built from source; its default environment is compiled in"
        echo "  so a fresh card needs no serial import." ;;
    *)
        echo "  note: no $BOOT_A2.layout. Treating the blob as the A2 partition."
        echo "  note: 'make uboot' builds one instead, with our environment in it." ;;
    esac
    A2_AT=2048
    A2_SECTORS="$SLAB_SECTORS"
    SLAB_AT="$A2_AT"          # the blob *is* the partition; write it there
fi
SLAB_AT="${SLAB_AT:-1}"       # a layout slab starts at sector 1
FAT_AT=$(( (A2_AT + A2_SECTORS + 2047) / 2048 * 2048 ))
FAT_SECTORS=$(( FAT_MB * 2048 ))
TOTAL=$(( FAT_AT + FAT_SECTORS ))

if [ "$SLAB_SECTORS" -ge 2048 ]; then
    BOOTSZ="$((SLAB_SECTORS / 2048)) MB"
else
    BOOTSZ="$((SLAB_SECTORS / 2)) KB"
fi
echo "  boot   $BOOT_A2  ($BOOTSZ at sector $A2_AT)"
echo "  fat    ${FAT_MB} MB at sector $FAT_AT (partition 1, what mmc 0:1 means)"
echo "  image  $OUT  ($((TOTAL / 2048)) MB)"

rm -f "$OUT"
truncate -s $(( TOTAL * 512 )) "$OUT"

# FAT is partition 1 and A2 is partition 2, even though A2 sits first on disk.
#
# Table order and disk order are independent, and the number is what matters:
# u-boot addresses a filesystem as mmc 0:<partition>, so the boot command says
# mmc 0:1 and MiSTer's cards are laid out the same way. Numbering A2 first gave
# a card where u-boot booted, found partition 1 was not a filesystem, and said
# "Can't set block device" three times before failing on a kernel it had never
# loaded.
#
# The BootROM does not care: it scans for the type, not the number.
sfdisk --quiet "$OUT" >/dev/null <<EOF
label: dos
start=$FAT_AT, size=$FAT_SECTORS, type=c, bootable
start=$A2_AT, size=$A2_SECTORS, type=a2
EOF

# A slab lifted from a card goes at sector 1, so the A2 partition and anything at
# a raw offset -- the u-boot environment, if it lives on the card rather than in
# flash -- land where they were. Sector 0 is ours; the slab does not include it.
#
# A bootloader built from source is just the partition's contents, so it goes at
# the partition.
dd if="$BOOT_A2" of="$OUT" bs=512 seek="$SLAB_AT" conv=notrunc status=none

# mtools works on an offset inside a file, so no loop device and no root.
export MTOOLS_SKIP_CHECK=1
MT="$OUT@@$(( FAT_AT * 512 ))"
mformat -i "$MT" -F -v BLITSCRT ::

# Copy the staged tree in, directories first so mcopy has somewhere to put things.
( cd "$STAGE" && find . -mindepth 1 -type d -printf '%P\n' ) | while read -r d; do
    mmd -i "$MT" "::$d" 2>/dev/null || true
done
( cd "$STAGE" && find . -mindepth 1 -type f -printf '%P\n' ) | while read -r f; do
    mcopy -i "$MT" -o "$STAGE/$f" "::$f"
done

SIZE_MB=$(( $(stat -c%s "$OUT") / 1048576 ))
echo
echo "wrote $(realpath "$OUT") (${SIZE_MB} MB)"
echo
echo "Write it to a card with Etcher, Raspberry Pi Imager, dd, or whatever you"
echo "already use. Nothing above touched a device -- an image is just a file."
echo
case "$BOOT_A2" in
*.sfp)
    echo "The boot command is compiled into this bootloader, so a card written"
    echo "from this image boots BlitsCRT on its own. No serial console, no"
    echo "u-boot prompt, nothing to import." ;;
*)
    echo "The bootloader came off a MiSTer card. Whether it also carries the"
    echo "boot environment depends on where u-boot keeps it -- if the card it"
    echo "came from already booted BlitsCRT, it does. If this one stops at a"
    echo "u-boot prompt or in MiSTer, import the environment once:"
    echo "docs/UBOOT_ENV.md, with blitsenv.txt already on the FAT partition." ;;
esac
