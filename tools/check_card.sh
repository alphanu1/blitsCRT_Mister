#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Is build/ a complete card?
#
# build/ is committed and is what a release ships, so a gap in it is a card that
# boots partway and stops. install_sd.sh copies whatever exists and says nothing
# about what does not, and `make world` skips whole steps when a toolchain is
# missing -- both reasonable on their own, and between them a file can go
# missing quietly.
#
# This is the same list the release workflow checks, so a local run tells you
# what CI would say before pushing.
#
#   tools/check_card.sh [build-dir]
#
# Exit 0 if complete, 1 if not.
set -u
DIR="${1:-build}"

# What the boot command loads, plus the bootloader and the tools worth shipping.
REQUIRED="
blitscrt.rbf
blitscrt.txt
blitscrt/zImage
blitscrt/blitscrt.dtb
blitscrt/blitscrtd
blitscrt/blitscrt-peek
blitscrt/gadget-setup.sh
u-boot-with-spl.sfp
"

# Nice to have. Absent is not an error.
OPTIONAL="
blitscrt/blitscrt-ddrbench
blitscrt/blitscrt-startup.sh
blitscrt/find-io.sh
blitscrt/blitscrt_gadget.config
"

fail=0
echo "card set in $DIR/"

for f in $REQUIRED; do
    if [ -s "$DIR/$f" ]; then
        printf '  ok       %-32s %s\n' "$f" "$(du -h "$DIR/$f" | cut -f1)"
    else
        printf '  MISSING  %-32s\n' "$f"
        fail=1
    fi
done

for f in $OPTIONAL; do
    [ -s "$DIR/$f" ] && printf '  ok       %-32s %s\n' "$f" "$(du -h "$DIR/$f" | cut -f1)"
done

if [ "$fail" != 0 ]; then
    cat <<'EOF'

  Incomplete. What produces each:

    blitscrt.rbf, blitscrt.txt      make bitstream   (needs Quartus)
    blitscrt/zImage, *.dtb          make linux       (needs a kernel tree)
    blitscrt/blitscrtd, -peek       make daemon peek (needs a cross-compiler)
    u-boot-with-spl.sfp             make uboot       (needs gcc 4/5/6)

  `make tools` shows which of those are available.
EOF
    exit 1
fi

echo "  complete -- 'make image' will build a card from this"
exit 0
