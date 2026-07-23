#!/bin/sh
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

# generated next to the bitstream so the .rbf name inside it always matches
if [ ! -f "$TXT" ]; then
    echo "generating $TXT" >&2
    python3 tools/gen_uboot_txt.py "$TXT" >&2
fi

# --- is this actually a MiSTer card? ---
missing=""
[ -f "$DEST/menu.rbf" ] || missing="$missing menu.rbf"
[ -f "$DEST/MiSTer" ]   || missing="$missing MiSTer"
[ -d "$DEST/linux" ]    || missing="$missing linux/"

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
others=$(find "$DEST" -maxdepth 1 -iname '*.txt' ! -iname 'blitscrt.txt' 2>/dev/null | wc -l)
if [ "$others" -gt 0 ]; then
    echo "NOTE: $others other .txt file(s) in the card root."
    echo "      MiSTer will show a picker rather than taking blitscrt.txt"
    echo "      automatically. Choose blitscrt.txt from the list."
    echo ""
fi

cp -v "$RBF"             "$DEST/blitscrt.rbf"
cp -v "$TXT"             "$DEST/blitscrt.txt"
sync

echo ""
echo "Done. Two files added, nothing else changed."
echo ""
echo "  Boot the MiSTer and select blitscrt.rbf from the menu."
echo "  It reboots once, then comes up on the test card."
echo "  Power cycle to return to MiSTer."
echo ""
echo "  Note: this works from the SD card only. MiSTer disables the hand-off"
echo "  for cores on USB storage."
