#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Teach u-boot's dtc version check about a leading "v".
#
# scripts/dtc-version.sh parses `dtc -v` to a four-digit number:
#
#   MAJOR=$($dtc -v | head -1 | awk '{print $NF}' | cut -d . -f 1)
#   printf "%02d%02d\n" $MAJOR $MINOR
#
# Some dtc builds print "Version: DTC 1.7.0" and some print "Version: DTC
# v1.7.2". On the second, MAJOR is "v1", printf refuses it, and the build stops
# at `checkdtc` with:
#
#   ./scripts/dtc-version.sh: line 20: printf: v1: invalid number
#
# MiSTer's tree is from 2018 and predates the versions that print the v. Strip
# it. Idempotent -- the marker says whether it has been done.
set -eu

UB="${1:?usage: uboot_fix_dtc.sh <u-boot-dir>}"
SCR="$UB/scripts/dtc-version.sh"

[ -f "$SCR" ] || exit 0                 # nothing to fix
grep -q 'blitsCRT' "$SCR" && exit 0     # already done
grep -q "sed 's/\^v//'" "$SCR" && exit 0

sed -i \
  -e "s|awk '{print \$NF}' | cut -d . -f|awk '{print \$NF}' \| sed 's/^v//' \| cut -d . -f|g" \
  "$SCR" 2>/dev/null || true

# The sed above is fragile against whitespace, so do it in python where the
# match can be exact, and only claim success if it took.
python3 - "$SCR" <<'PYEOF'
import re, sys
path = sys.argv[1]
src = open(path).read()
if 'blitsCRT' in src:
    sys.exit(0)
new, n = re.subn(r"(\$dtc -v \| head -1 \| awk '\{print \$NF\}')( \|)",
                 r"\1 | sed 's/^v//'\2", src)
if n:
    new = ("#!/bin/sh\n# blitsCRT: leading 'v' stripped from the dtc version, "
           "which this 2018 script\n# does not expect and printf will not accept.\n"
           + new.split('\n', 1)[1])
    open(path, 'w').write(new)
    print('patched %d' % n)
else:
    print('no match')
PYEOF
