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
    # Only a real count, not the section heading. This used to match the
    # words anywhere in the report -- including its own table of contents --
    # so it fired on every build and meant nothing.
    m = re.search(r'Unconstrained Clocks\s*;\s*(\d+)\s*;\s*(\d+)', txt)
    if m and (int(m.group(1)) or int(m.group(2))):
        problems.append('%s: %s unconstrained clocks -- those paths are not '
                        'timed at all' % (rpt, m.group(1)))

    # Slack. The check ran for weeks without looking at it, and reported PASS
    # on a design carrying -5.641 ns of setup slack and -214 ns of TNS.
    #
    # A path that misses timing is not wrong, it is late: the logic is right,
    # every counter reads clean, and the value is occasionally sampled before
    # it settles. That is a hard fault to place from behaviour, and exactly
    # the kind a report is supposed to hand you for free.
    # The boxed heading, not the entry in the report's own table of contents.
    #
    # A plain find() matches the contents listing first and then scans the legal
    # notice, finds no table, and says so -- which is how this check reported
    # "no multicorner summary" on a report that had one, carrying -5.641 ns.
    # The same mistake as the unconstrained-clocks check above: matching a
    # heading rather than the thing under it.
    mm = re.search(r'^;\s*Multicorner Timing Analysis Summary', txt, re.M)
    i = mm.start() if mm else -1
    if i >= 0:
        seen = False
        for line in txt[i:i + 8000].split('\n'):
            if not line.startswith(';'):
                continue
            cells = [c.strip() for c in line.split(';')[1:-1]]
            # Skip the summary's own header and its roll-up rows: they carry
            # the same number as the clock that caused them, and reporting one
            # fault three times reads like three faults.
            if len(cells) < 2 or not cells[0]:
                continue
            if cells[0].startswith('Design-wide') or \
               cells[0].startswith('Worst-case') or \
               cells[0] in ('Clock', 'Type', 'Slack'):
                continue
            try:
                setup = float(cells[1])
            except ValueError:
                continue
            seen = True
            short = cells[0] if len(cells[0]) < 58 else '...' + cells[0][-55:]
            if setup < 0.0:
                # The output pads are constrained tighter than they can be met,
                # on purpose. What matters on VGA_R/G/B and HDMI_TX_D is skew
                # between the bits of a bus -- the DAC and the ADV7513 latch
                # them on one edge -- and an unachievable max-delay makes the
                # fitter minimise every path as hard as it can, which bunches
                # them. Relaxing it to something meetable let the fitter stop
                # early, the bits spread, and the colour on a CRT went wrong.
                #
                # So a failing 'n/a' clock here is expected. Report it, do not
                # fail on it. Anything with a real clock name still fails.
                if cells[0].strip() in ('n/a', ''):
                    notes.append('setup slack %+.3f ns on the output pads -- '
                                 'expected, see blitscrt.sdc' % setup)
                else:
                    problems.append('setup slack %+.3f ns on %s -- the design '
                                    'does not meet timing' % (setup, short))
        if not seen:
            notes.append('%s: could not read slack from the multicorner summary'
                         % rpt)
    elif rpt.endswith('sta.rpt'):
        # Only the timing report is expected to carry one; the fit report is
        # not, and saying so every build is the noise this check exists to
        # avoid.
        notes.append('%s has no multicorner summary -- read the timing by hand'
                     % rpt)

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
