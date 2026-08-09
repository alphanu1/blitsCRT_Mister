#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# s_ctrl and ctrl_vid must reset to the same value.
#
# s_ctrl is the register the bus sees; ctrl_vid is its two-flop copy in the
# video domain. Until software writes CTRL, the video side runs on ctrl_vid's
# reset value alone -- so if the two disagree, the fabric comes up with control
# bits the register does not report.
#
# They disagreed. Widening the synchroniser from 6 bits to 9 was typed as
# 0_1001_0110 against the register's 0_1001_1110, dropping bit 3: CSYNC. The
# picture still appeared, because a set free-runs close enough to lock, but it
# recovered its AGC and black level from a pin with no composite sync on it and
# came up with the levels visibly wrong.
#
# Nothing caught it. Both literals are legal, the design elaborates, every
# simulation passes, and the only symptom is on a CRT.

import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else 'rtl/blitscrt_regs.v'
text = open(path).read()


def literal(pattern):
    m = re.search(pattern, text)
    if not m:
        return None
    return int(m.group(1).replace('_', ''), 2)


bus = literal(r"s_ctrl\s*<=\s*9'b([01_]+)")
vid = literal(r"ctrl_vid\s*<=\s*9'b([01_]+)")

if bus is None or vid is None:
    print('could not find both reset values in %s' % path)
    sys.exit(1)

if bus != vid:
    diff = [b for b in range(9) if ((bus >> b) & 1) != ((vid >> b) & 1)]
    names = {0: 'ENABLE', 1: 'TESTCARD', 2: 'OVERLAY', 3: 'CSYNC',
             4: 'HDMI_EN', 5: 'HPS_TIMING', 6: 'AV_FORCE', 7: 'AV_DAC',
             8: 'AV_CLK_INV'}
    print('CTRL reset values disagree:')
    print('  s_ctrl   0x%03X  %s' % (bus, format(bus, '09b')))
    print('  ctrl_vid 0x%03X  %s' % (vid, format(vid, '09b')))
    for b in diff:
        print('  bit %d %s differs' % (b, names.get(b, '?')))
    sys.exit(1)

print('CTRL resets agree (0x%03X)' % bus)
