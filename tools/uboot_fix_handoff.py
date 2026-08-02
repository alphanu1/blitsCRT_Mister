#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Give mainline u-boot's preloader MiSTer's hardware handoff.
#
# The preloader configures DDR3, the PLLs, the pin mux and -- the part that
# matters here -- the FPGA-to-SDRAM ports, all from four generated headers in
# board/terasic/de10-nano/qts/. Those settings are latched by APPLYCFG while the
# SDRAM interface is idle, which is the preloader's job at boot and cannot be
# redone from Linux.
#
# Mainline's headers are the stock DE10-Nano's. MiSTer's differ, and one
# difference stops scanout dead:
#
#   FPGAPORTRST      MiSTer 0x3FFF      mainline 0x1FF
#
# Nine ports enabled instead of fourteen. rtl/mister/sysmem.sv wires three
# f2sdram ports and they land in bits mainline never enables, so the fabric asks
# for scanout data and gets nothing back:
#
#   last line   0 beats
#   underruns   255 (saturated)
#
# Everything else works -- the test card is generated inside the fabric and
# displays perfectly, and the USB side delivers whole frames into DDR3. Only the
# read path out of it is dead.
#
# The others matter too. S2FUSER1CLK and S2FUSER2CLK are the FPGA-facing PLL
# outputs, and the iocsr and pinmux tables are this board's IO calibration.
#
# Writing FPGAPORTRST at runtime does not work and hangs the board. It has to be
# latched before the SDRAM controller is running.
#
# The headers are BSD-3-Clause and are generated output from the hardware
# project, so copying them is straightforward. Upstream renamed the macro prefix
# from CONFIG_ to CFG_, which is the only edit made on the way.

import os
import re
import sys

MARK = 'blitsCRT: handoff from MiSTer'
QTS = 'board/terasic/de10-nano/qts'
FILES = ('sdram_config.h', 'pll_config.h', 'iocsr_config.h', 'pinmux_config.h')


def main():
    if len(sys.argv) not in (2, 3):
        print('usage: uboot_fix_handoff.py <u-boot-dir> [<source-dir>]',
              file=sys.stderr)
        return 2

    dst_root = sys.argv[1]
    dst_dir = os.path.join(dst_root, QTS)

    if len(sys.argv) == 3:
        # An explicit source, for refreshing from a u-boot_MiSTer checkout.
        src_dir = os.path.join(sys.argv[2], QTS)
    else:
        # The copy kept in this repository. BSD-3-Clause generated output, so it
        # can live here -- which means no second u-boot clone just to read four
        # headers out of it.
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        src_dir = os.path.join(here, 'uboot', 'de10-nano-qts')

    if not os.path.isdir(dst_dir):
        print('no %s -- is that a u-boot tree?' % dst_dir, file=sys.stderr)
        return 1
    if not os.path.isdir(src_dir):
        print('no %s' % src_dir, file=sys.stderr)
        return 1

    # Does this tree use CFG_ or CONFIG_? Read it rather than assume.
    probe = open(os.path.join(dst_dir, 'sdram_config.h')).read()
    prefix = 'CFG_' if '#define CFG_HPS_' in probe else 'CONFIG_'

    copied = 0
    for name in FILES:
        dst = os.path.join(dst_dir, name)
        src = os.path.join(src_dir, name)

        if not os.path.exists(src):
            print('missing %s' % src, file=sys.stderr)
            return 1

        if MARK in open(dst).read():
            continue

        text = open(src).read()
        if prefix == 'CFG_':
            text = re.sub(r'^#define\s+CONFIG_', '#define CFG_', text,
                          flags=re.M)

        header = ('/*\n * %s.\n *\n'
                  " * Generated from MiSTer's hardware project rather than the\n"
                  ' * stock DE10-Nano one, because rtl/mister/sysmem.sv expects\n'
                  " * MiSTer's f2sdram port configuration. BSD-3-Clause, as the\n"
                  ' * original.\n */\n' % MARK)
        open(dst, 'w').write(header + text)
        copied += 1

    if copied:
        print('handoff replaced (%d files)' % copied)
    else:
        print('already patched')
    return 0


sys.exit(main())
