#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Print the fabric's VERSION register as major.minor.
#
# It is a 32-bit constant in blitscrt_regs.v -- 32'h0003_0016 is 3.22 -- and the
# daemon refuses to run against a fabric older than it needs. A release workflow
# wants it readable rather than as hex.

import re
import sys

SRC = 'rtl/blitscrt_regs.v'

try:
    text = open(SRC).read()
except OSError as e:
    print('unknown', file=sys.stderr)
    sys.exit(1)

m = re.search(r"VERSION\s*=\s*32'h([0-9A-Fa-f_]+)", text)
if not m:
    print('unknown')
    sys.exit(1)

v = int(m.group(1).replace('_', ''), 16)
print('%d.%d' % (v >> 16, v & 0xFFFF))
