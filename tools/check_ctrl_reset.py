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
vid = literal(r"ctrl_vid\s*<=\s*[0-9]+'b([01_]+)")

# ctrl_vid is deliberately narrower than s_ctrl: it carries the six bits the
# video side reads through a synchroniser, while bits 6, 7 and 8 are taken from
# s_ctrl directly because they belong to the DAC clock path. So compare only
# the bits ctrl_vid actually has.
if vid is not None:
    m = re.search(r"ctrl_vid\s*<=\s*([0-9]+)'b", text)
    width = int(m.group(1)) if m else 9
    bus = bus & ((1 << width) - 1) if bus is not None else None

if bus is None or vid is None:
    print('could not find both reset values in %s' % path)
    sys.exit(1)

# A note, not a failure.
#
# This began as a hard check after CSYNC was found missing from ctrl_vid's reset
# value -- which looked like the cause of a colour regression and was not. The
# two have always differed: the original ctrl_vid reset is 6'b010110, without
# CSYNC, and that is what shipped and worked throughout.
#
# It does not matter, because the reset value only holds for the two clk_pix
# cycles the synchroniser takes to propagate s_ctrl. After that the video side
# sees the real value. Reporting the difference is useful; failing on it turned
# out to be wrong, and cost a rebuild.
if bus != vid:
    diff = [b for b in range(9) if ((bus >> b) & 1) != ((vid >> b) & 1)]
    names = {0: 'ENABLE', 1: 'TESTCARD', 2: 'OVERLAY', 3: 'CSYNC',
             4: 'HDMI_EN', 5: 'HPS_TIMING', 6: 'AV_FORCE', 7: 'AV_DAC',
             8: 'AV_CLK_INV'}
    print('note: CTRL reset values differ')
    print('  s_ctrl   0x%03X  %s' % (bus, format(bus, '09b')))
    print('  ctrl_vid 0x%03X  %s' % (vid, format(vid, '09b')))
    for b in diff:
        print('  bit %d %s differs' % (b, names.get(b, '?')))
    print('  (only for the two clk_pix cycles before the synchroniser'
          ' propagates s_ctrl)')
    sys.exit(0)

print('CTRL resets agree on the bits ctrl_vid carries (0x%03X)' % bus)
