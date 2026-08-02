#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Replace CONFIG_BOOTCOMMAND in a u-boot board header.
#
# MiSTer's u-boot is from 2018 and keeps the boot command as a #define in
# include/configs/socfpga_de10_nano.h rather than as a Kconfig symbol. Setting
# CONFIG_BOOTCOMMAND in .config therefore does nothing: olddefconfig drops the
# unknown symbol and the built bootloader keeps MiSTer's own command, which
# looks for menu.rbf and MiSTer's kernel and finds neither on our card.
#
# Idempotent. A marker comment records that it has been done, so rebuilding does
# not stack edits, and the original line is kept beside it so it is clear what
# was replaced.
#
#   uboot_patch_header.py <header> <boot command>

import re
import sys

MARK = 'blitsCRT: boot command'

if len(sys.argv) != 3:
    print('usage: uboot_patch_header.py <header> <command>', file=sys.stderr)
    sys.exit(2)

path, cmd = sys.argv[1], sys.argv[2]
src = open(path).read()

if MARK in src:
    print('already patched')
    sys.exit(0)

escaped = cmd.replace('\\', '\\\\').replace('"', '\\"')
replacement = (
    '/* ' + MARK + ', from tools/uboot_env.txt. The original is kept\n'
    ' * below so it is clear what was replaced. */\n'
    '#define CONFIG_BOOTCOMMAND\t"' + escaped + '"\n'
)

out, n = re.subn(
    r'^#define\s+CONFIG_BOOTCOMMAND\s+(.*)$',
    lambda m: replacement + '/* was: ' + m.group(1).replace('*/', '*_/') + ' */',
    src, count=1, flags=re.M)

if n != 1:
    print('no CONFIG_BOOTCOMMAND in ' + path, file=sys.stderr)
    sys.exit(1)

open(path, 'w').write(out)
print('patched')
