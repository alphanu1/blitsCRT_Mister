#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Print the path of an ARM gcc old enough to build MiSTer's u-boot, or nothing.
#
# MiSTer's tree is u-boot 2017.03 and their wiki asks for gcc 4 or 5; a modern
# compiler produces an SPL that hangs at its own banner. So this looks for one,
# by asking each compiler its version rather than by guessing where it lives --
# neither the directory nor the binary prefix is predictable:
#
#   Bootlin's 2017 tarball unpacks to armv7-eabihf--glibc--stable, not to its
#   own filename, and their binaries are named by the buildroot triple, which
#   has changed across releases.
#
# Searches $1 if given, otherwise ~/toolchains.
set -u
root="${1:-$HOME/toolchains}"

for g in "$root"/*/bin/*-gcc; do
    [ -x "$g" ] || continue
    v=$("$g" -dumpversion 2>/dev/null | cut -d. -f1)
    if [ "$v" = 4 ] || [ "$v" = 5 ] || [ "$v" = 6 ]; then
        echo "$g"
        exit 0
    fi
done
exit 0
