#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check that the altclkctrl slot constants agree across modules.

On Cyclone V, altclkctrl accepts PLL outputs only on inclk[2] and inclk[3];
slots 0 and 1 must be driven by real clock pins, and pll_modes.v wires the
50 MHz reference there to satisfy the placement rule. So a clock select of 0 or
1 does not choose a pixel clock at all -- it chooses the reference.

mode_table.v names the full-rate slot CLK_12M6 and blitscrt_top.v names it
CLK_FULL, for the host-owns-timing path. They must be the same number. When they
were not, setting CTRL_HPS_TIMING clocked 640x480i timing off 50 MHz, a line
rate near 62 kHz, and the only symptom was a monitor refusing to sync.

Usage:
    python3 tools/check_clk_sel.py
"""
import re
import sys

def find(path, name):
    txt = open(path).read()
    m = re.search(r"localparam\s*\[1:0\]\s*%s\s*=\s*2'd(\d)" % name, txt)
    return int(m.group(1)) if m else None

full = find('rtl/blitscrt_top.v', 'CLK_FULL')
m126 = find('rtl/mode_table.v', 'CLK_12M6')
m252 = find('rtl/mode_table.v', 'CLK_25M2')

if full is None or m126 is None:
    print('RESULT: FAIL  could not find CLK_FULL or CLK_12M6')
    sys.exit(1)

print('  blitscrt_top CLK_FULL = %d' % full)
print('  mode_table   CLK_12M6 = %d, CLK_25M2 = %s' % (m126, m252))

bad = []
if full != m126:
    bad.append('CLK_FULL (%d) != CLK_12M6 (%d): the host-owns-timing path and '
               'the mode table would select different clocks' % (full, m126))
for n, v in (('CLK_FULL', full), ('CLK_12M6', m126), ('CLK_25M2', m252)):
    if v is not None and v < 2:
        bad.append('%s = %d selects a clock pin, not a PLL output' % (n, v))

if bad:
    print()
    for b in bad:
        print('  PROBLEM: %s' % b)
    print()
    print('RESULT: FAIL')
    sys.exit(1)
print('RESULT: PASS  clock slot constants agree and select PLL outputs')
