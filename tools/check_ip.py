#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check the generated PLL megafunctions carry the settings the design needs.

GUI labels move between Quartus releases, so this reads what came out rather
than trusting what was ticked. Run after generating the IP:

    python3 tools/check_ip.py

The one thing that silently breaks everything is generating the PLL without
reconfiguration enabled: it builds, it runs, and the clock never changes.
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Frequencies the advertised modes need at power-on, in MHz.
WANT_CLOCKS = [12.6, 6.3]
TOLERANCE = 0.05


def find_ip(name):
    """Generated IP lands in rtl/<name>/ or anywhere under rtl/."""
    hits = []
    for pat in ("rtl/%s/*.v" % name, "rtl/%s/*.sv" % name,
                "rtl/%s.v" % name, "rtl/**/%s*.v" % name):
        hits += glob.glob(os.path.join(ROOT, pat), recursive=True)
    return sorted(set(hits))


def read(paths):
    text = ""
    for p in paths:
        try:
            text += open(p, errors="replace").read()
        except OSError:
            pass
    return text


def report(label, ok, detail=""):
    """detail is a hint about the failure, so it only belongs on failure."""
    print("  %-46s %s%s" % (label, "ok" if ok else "FAIL",
                            ("  " + detail) if (detail and not ok) else ""))
    return 0 if ok else 1


def main():
    bad = 0

    print("Altera PLL")
    pll_files = find_ip("pll_pix")
    if not pll_files:
        print("  not generated yet -- see docs/MEGAFUNCTIONS.md")
        print("  expected under rtl/pll_pix/")
        return 0                       # nothing to check, not a failure

    src = read(pll_files)
    print("  %d file(s) under rtl/pll_pix/" % len(pll_files))

    bad += report("reconfig_to_pll port present",
                  "reconfig_to_pll" in src,
                  "reconfiguration is off; the clock will never change")
    bad += report("reconfig_from_pll port present",
                  "reconfig_from_pll" in src)
    bad += report("locked output present", "locked" in src)

    frac = re.search(r'fractional_vco_multiplier\s*=\s*"?(\w+)', src)
    if frac:
        bad += report("integer-N mode", frac.group(1).lower() == "false",
                      "fractional changes the counter encoding")

    # The generated wrapper writes these as `= "12.600000 MHz"`, the inline
    # form as `("12.600000 MHz")`. Accept either.
    freqs = [float(f) for f in
             re.findall(r'output_clock_frequency\d+\s*[=(]\s*"([\d.]+)\s*MHz',
                        src)]
    if freqs:
        print("  output clocks: %s MHz" % ", ".join("%.3f" % f for f in freqs))
        for want in WANT_CLOCKS:
            hit = any(abs(f - want) < TOLERANCE for f in freqs)
            bad += report("%.3f MHz present" % want, hit)
        if len(freqs) >= 2:
            ratio = max(freqs[:2]) / min(freqs[:2])
            bad += report("the two outputs are 2:1", abs(ratio - 2.0) < 0.01,
                          "ratio %.4f" % ratio)

    print("")
    print("Altera PLL Reconfig")
    rc_files = find_ip("pll_reconfig")
    if not rc_files:
        print("  not generated yet -- see docs/MEGAFUNCTIONS.md")
        print("  expected under rtl/pll_reconfig/")
        return 1 if bad else 0

    rsrc = read(rc_files)
    print("  %d file(s) under rtl/pll_reconfig/" % len(rc_files))
    for port in ("mgmt_clk", "mgmt_address", "mgmt_write", "mgmt_writedata",
                 "mgmt_read", "mgmt_readdata", "mgmt_waitrequest",
                 "reconfig_to_pll", "reconfig_from_pll"):
        bad += report("%s present" % port, port in rsrc)

    m = re.search(r'mgmt_address\s*\[\s*(\d+)\s*:', rsrc)
    if m:
        width = int(m.group(1)) + 1
        bad += report("mgmt_address wide enough for the map", width >= 3,
                      "%d bits, need at least 3 for addresses 0..7" % width)

    print("")
    print("Project wiring")
    qsf = os.path.join(ROOT, "quartus", "blitscrt.qsf")
    q = open(qsf, errors="replace").read() if os.path.exists(qsf) else ""
    bad += report("pll_pix.qip added to the project", "pll_pix.qip" in q)
    bad += report("pll_reconfig.qip added to the project",
                  "pll_reconfig.qip" in q)

    print("")
    print("Still to confirm against the guide for this IP version:")
    print("  register addresses in sw/pll_reconfig.h")
    print("  counter field width, PLL_CNT_FIELD_BITS, currently 8 (divide <= 510)")

    print("")
    print("FAIL" if bad else "PASS")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
