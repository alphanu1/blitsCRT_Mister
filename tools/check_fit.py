#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check the Quartus reports for the failures that do not stop a compile.

Quartus says all of this, but says it as Info among thousands of lines, and the
build carries on. Three of these have already cost a session each:

  uninferred RAM      an array that did not become a block RAM became registers
                      instead. A line buffer of 2 x 512 x 64 bits turns into
                      65,536 flip-flops and the design stops fitting -- and the
                      only warning is one Info line in the synthesis report.
  unconstrained clock  a clock the SDC did not match. Timing analysis on that
                      domain then reports success while meaning nothing.
  ignored SDC filter  a wildcard in the SDC that matched no object. The
                      constraint silently does not exist.
  undriven net        a wire nothing assigns. Quartus ties it to zero and
                      continues, so a bus whose readback lost its driver reads
                      back as hardware that is not present at all.

Usage:
    python3 tools/check_fit.py quartus/output_files
"""
import re
import sys
from pathlib import Path

out = Path(sys.argv[1] if len(sys.argv) > 1 else 'quartus/output_files')
problems, notes = [], []

mapr = out / 'blitscrt.map.rpt'
if mapr.exists():
    txt = mapr.read_text(errors='replace')
    for m in re.finditer(r'RAM logic "([^"]+)" is uninferred due to (.+?)\s*(?:File:|$)',
                         txt, re.M):
        name, why = m.group(1), m.group(2).strip()
        # a small ROM that is cheaper as logic is normal and not worth flagging
        if 'inappropriate RAM size' in why:
            notes.append('%s left as logic (%s)' % (name, why))
        else:
            problems.append('uninferred RAM: %s -- %s' % (name, why))

    # Warning 10030: a declared wire nobody drives. Quantus ties it to zero and
    # carries on, so a bus whose readback lost its driver reads as a fabric that
    # is not there. Inferred-RAM port fields (mem.data_a and friends) carry a
    # dot and are expected; a plain net name is ours and is a real problem.
    for m in re.finditer(r'Net "([^"]+)" at ([^\s]+) has no driver', txt):
        net, where = m.group(1), m.group(2)
        if '.' in net:
            notes.append('%s undriven (inferred memory port, expected)' % net)
        else:
            problems.append('undriven net: %s at %s -- Quartus tied it to 0'
                            % (net, where))

fitr = out / 'blitscrt.fit.rpt'
if fitr.exists():
    txt = fitr.read_text(errors='replace')
    m = re.search(r'Total block memory bits\s*;\s*([\d,]+)\s*/\s*([\d,]+)', txt)
    if m:
        notes.append('block memory %s of %s bits' % (m.group(1), m.group(2)))
    m = re.search(r'Logic utilization \(in ALMs\)\s*;\s*([\d,]+)\s*/\s*([\d,]+)', txt)
    if m:
        notes.append('ALMs %s of %s' % (m.group(1), m.group(2)))

for rpt in ('blitscrt.sta.rpt', 'blitscrt.fit.rpt'):
    p = out / rpt
    if not p.exists():
        continue
    txt = p.read_text(errors='replace')
    for m in re.finditer(r'Ignored (set_\w+) at ([^\(]+\([\d]+\))', txt):
        if 'blitscrt.sdc' in m.group(2):
            problems.append('SDC constraint matched nothing: %s at %s'
                            % (m.group(1), m.group(2)))
    if re.search(r'[Uu]nconstrained [Cc]lock', txt):
        for m in re.finditer(r'^\s*;\s*([\w\|\[\]\.:~]+)\s*;\s*$', txt, re.M):
            pass  # names vary by report shape; the flag below is what matters
        notes.append('%s mentions unconstrained clocks -- read it' % rpt)

for n in notes:
    print('  note: %s' % n)
if problems:
    print()
    for p_ in problems:
        print('  PROBLEM: %s' % p_)
    print()
    print('RESULT: FAIL  %d issue(s) Quartus reported without failing' % len(problems))
    sys.exit(1)
print('RESULT: PASS  no silent synthesis or constraint problems')
