#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Hash everything the bitstream is built from, so rebuilds follow content.

The up-to-date check used to be `find $(RTL_SRCS) -newer $(RBF)`, which is right
until the tree arrives as an archive. Extracting a zip stamps every file with the
time of extraction, so all of it looks newer than the .rbf and Quartus recompiles
-- minutes, for a release that only changed the daemon.

Hashing the sources instead means the fabric rebuilds when the fabric changes and
not otherwise, however the files got onto disk.

What counts as a fabric source: the RTL, the generated .hex the RTL reads with
$readmemh, the .qsf and the .sdc, and pins.tcl. Anything whose content ends up in
the bitstream. Not the software, not the kernel, not the docs.

Usage:
    tools/rtl_hash.py                 print the hash
    tools/rtl_hash.py --check FILE    exit 0 if FILE holds the same hash
    tools/rtl_hash.py --write FILE    write the hash to FILE
"""

import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

PATTERNS = [
    "rtl/*.v", "rtl/*.sv", "rtl/*.hex",
    "rtl/*/*.v", "rtl/*/*.sv",
    "quartus/blitscrt.qsf", "quartus/blitscrt.sdc", "quartus/pins.tcl",
]


def sources():
    seen = set()
    for pat in PATTERNS:
        for p in sorted(ROOT.glob(pat)):
            if p.is_file():
                seen.add(p)
    return sorted(seen)


def digest():
    h = hashlib.sha256()
    for p in sources():
        # The path goes in as well as the content, so adding or removing a file
        # changes the hash even if the remaining bytes are identical.
        h.update(str(p.relative_to(ROOT)).encode())
        h.update(b"\0")
        h.update(p.read_bytes())
    return h.hexdigest()


def main():
    d = digest()
    args = sys.argv[1:]

    if not args:
        print(d)
        return 0

    if args[0] == "--check" and len(args) == 2:
        f = Path(args[1])
        if not f.is_file():
            return 1
        return 0 if f.read_text().strip() == d else 1

    if args[0] == "--write" and len(args) == 2:
        f = Path(args[1])
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(d + "\n")
        print("  fabric hash %s" % d[:16])
        return 0

    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
