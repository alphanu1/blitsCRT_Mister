#!/usr/bin/env python3
"""Verify pin assignments.

Two checks, both of which have bitten this project's ancestor:

  1. Every port on blitscrt_top has a location assignment. A port without one
     gets auto-placed by the Fitter onto an arbitrary ball, which is how a
     design ends up with its clock on the wrong pin and no picture.

  2. Every assignment matches the MiSTer framework, when a copy of
     Template_MiSTer is available to compare against. These are facts about how
     the board is wired.

Usage:
    python3 tools/check_pins.py [path/to/Template_MiSTer]
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOP = os.path.join(ROOT, 'rtl', 'blitscrt_top.v')
PINS = os.path.join(ROOT, 'quartus', 'pins.tcl')


def parse_locations(paths, include_commented=False):
    out = {}
    for path in paths:
        if not os.path.exists(path):
            continue
        for line in open(path, errors='replace'):
            s = line.strip()
            commented = s.startswith('#')
            if commented and not include_commented:
                continue
            body = s.lstrip('#').strip()
            m = re.match(r'set_location_assignment\s+(PIN_\S+)\s+-to\s+(\S+)', body)
            if m:
                out[m.group(2)] = (m.group(1), commented)
    return out


def parse_ports(path):
    """Pull the port list out of the module header, expanding vectors."""
    src = open(path, errors='replace').read()
    src = re.sub(r'//[^\n]*', '', src)
    m = re.search(r'module\s+blitscrt_top\s*(#\s*\([^)]*\)\s*)?\((.*?)\)\s*;',
                  src, re.S)
    if not m:
        raise SystemExit("could not find the blitscrt_top port list")

    ports = []
    for decl in m.group(2).split(','):
        decl = decl.strip()
        if not decl:
            continue
        d = re.match(r'(input|output|inout)\s+(?:wire|reg)?\s*'
                     r'(?:\[\s*(\d+)\s*:\s*(\d+)\s*\]\s*)?(\w+)', decl)
        if not d:
            continue
        hi, lo, name = d.group(2), d.group(3), d.group(4)
        if hi is None:
            ports.append(name)
        else:
            for i in range(int(lo), int(hi) + 1):
                ports.append("%s[%d]" % (name, i))
    return ports


def main():
    ours = parse_locations([PINS], include_commented=True)
    active = {k: v for k, v in ours.items() if not v[1]}
    ports = parse_ports(TOP)

    print("blitscrt_top ports:      %d" % len(ports))
    print("active pin assignments:  %d" % len(active))
    print("commented out (for M3):  %d" % (len(ours) - len(active)))
    print()

    unassigned = [p for p in ports if p not in active]
    orphans = [p for p in active if p not in ports]

    fail = False

    if unassigned:
        fail = True
        print("FAIL  ports with no location assignment (the Fitter will place")
        print("      these itself, anywhere it likes):")
        for p in unassigned:
            print("        %s" % p)
    else:
        print("PASS  every port has a location assignment")

    if orphans:
        print()
        print("NOTE  assigned but not a port on the current top level:")
        for p in sorted(orphans):
            print("        %-16s %s" % (p, active[p][0]))

    # optional cross-check against the MiSTer framework
    ref = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('MISTER_TEMPLATE')
    if ref:
        mis = parse_locations([os.path.join(ref, 'sys', 'sys.tcl'),
                               os.path.join(ref, 'sys', 'sys_analog.tcl')])
        if not mis:
            print()
            print("NOTE  no sys.tcl / sys_analog.tcl under %s" % ref)
        else:
            print()
            # both sides are (pin, commented) tuples; compare the pin only
            mismatch = [(s, ours[s][0], mis[s][0]) for s in ours
                        if s in mis and ours[s][0] != mis[s][0]]
            checked = [s for s in ours if s in mis]
            unknown = [s for s in ours if s not in mis]
            print("cross-check against MiSTer (%d reference assignments):" % len(mis))
            print("  compared  %d" % len(checked))
            print("  mismatch  %d" % len(mismatch))
            print("  not in reference  %d" % len(unknown))
            for s, a, b in mismatch:
                fail = True
                print("    FAIL %-16s ours=%-8s mister=%s" % (s, a, b))
            for s in sorted(unknown):
                print("    NOTE %-16s %s has no MiSTer reference"
                      % (s, ours[s][0]))
    else:
        print()
        print("No MiSTer tree given, skipping the cross-check. To run it:")
        print("  python3 tools/check_pins.py /path/to/Template_MiSTer")

    print()
    print("RESULT: %s" % ("FAIL" if fail else "PASS"))
    return 1 if fail else 0


if __name__ == '__main__':
    sys.exit(main())
