#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Set dr_mode = "peripheral" on the HPS OTG controller in a built device tree.

blitscrt.dtb is the stock socfpga_cyclone5_de10_nano.dtb, copied and renamed, and
that tree leaves dwc2 in host mode. Correct for MiSTer, where the OTG port carries
the USB hub for keyboards and joysticks -- wrong here, where the port has to be a
device so a host can enumerate it as a display.

Confirmed on hardware: with the stock tree, /sys/class/udc/ is empty while dmesg
shows dwc2 enumerating that hub downstream. No UDC means no gadget, whatever
configfs is told.

This goes through dtc rather than fdtput. dtc is already required to build the
kernel, whereas the libfdt tools (fdtput, fdtget, fdtdump) ship separately on some
distributions and are easy not to have -- and the failure was silent enough to
cost a boot: the script bailed, the unpatched dtb went to the card, and the
symptom was identical to having done nothing.

Patching the built dtb rather than the kernel source keeps the kernel tree stock,
so `make world` stays reproducible against an unmodified checkout.

Usage: tools/set_dr_mode.py build/blitscrt/blitscrt.dtb
"""

import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

WANT = "peripheral"


def die(msg):
    print("set_dr_mode: %s" % msg, file=sys.stderr)
    sys.exit(1)


def decompile(dtb):
    try:
        r = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", str(dtb)],
                           capture_output=True, text=True)
    except FileNotFoundError:
        die("dtc not found (install device-tree-compiler)")
    if r.returncode != 0:
        die("dtc could not read %s:\n%s" % (dtb, r.stderr.strip()))
    return r.stdout


def recompile(dts_text, out):
    with tempfile.NamedTemporaryFile("w", suffix=".dts", delete=False) as f:
        f.write(dts_text)
        tmp = f.name
    r = subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", str(out), tmp],
                       capture_output=True, text=True)
    Path(tmp).unlink(missing_ok=True)
    if r.returncode != 0:
        die("dtc could not rebuild the tree:\n%s" % r.stderr.strip())


def patch(text):
    """Set dr_mode on every enabled USB controller node.

    On Cyclone V the two are usb@ffb00000 and usb@ffb40000; the OTG connector on
    a DE10-Nano is the second, and the other is normally disabled. Rather than
    hardcode which, take whichever is status = "okay" -- a disabled controller is
    not the port anything is plugged into.
    """
    lines = text.split("\n")
    out = []
    i = 0
    touched = []

    node_re = re.compile(r'^\s*usb@([0-9a-fA-F]+)\s*\{')

    while i < len(lines):
        m = node_re.match(lines[i])
        if not m:
            out.append(lines[i])
            i += 1
            continue

        # Collect the whole node by brace depth so nested nodes come with it.
        start = i
        depth = 0
        body = []
        while i < len(lines):
            depth += lines[i].count("{") - lines[i].count("}")
            body.append(lines[i])
            i += 1
            if depth == 0:
                break

        blob = "\n".join(body)
        addr = m.group(1)

        status = re.search(r'status\s*=\s*"([^"]+)"', blob)
        if status and status.group(1) != "okay":
            out.extend(body)
            continue

        indent = re.match(r'^(\s*)', lines[start]).group(1) + "\t"
        cur = re.search(r'dr_mode\s*=\s*"([^"]+)"', blob)
        if cur:
            if cur.group(1) == WANT:
                touched.append((addr, "already " + WANT))
            else:
                blob = re.sub(r'dr_mode\s*=\s*"[^"]+"',
                              'dr_mode = "%s"' % WANT, blob, count=1)
                touched.append((addr, "%s -> %s" % (cur.group(1), WANT)))
        else:
            # No dr_mode at all: add one just inside the node.
            blob = blob.replace("{", '{\n%sdr_mode = "%s";' % (indent, WANT), 1)
            touched.append((addr, "unset -> %s" % WANT))

        out.extend(blob.split("\n"))

    return "\n".join(out), touched


def main():
    if len(sys.argv) != 2:
        die("usage: set_dr_mode.py <dtb>")
    dtb = Path(sys.argv[1])
    if not dtb.is_file():
        die("%s does not exist" % dtb)

    text = decompile(dtb)
    patched, touched = patch(text)

    if not touched:
        die("no enabled USB controller found in %s.\n"
            "  Look for the node with:  dtc -I dtb -O dts %s | grep -n 'usb@'"
            % (dtb, dtb))

    # Keep a copy of the original the first time, so the stock tree is
    # recoverable without rebuilding the kernel.
    backup = dtb.with_suffix(dtb.suffix + ".orig")
    if not backup.exists():
        shutil.copy2(dtb, backup)

    recompile(patched, dtb)

    for addr, what in touched:
        print("  usb@%s: dr_mode %s" % (addr, what))
    print("  /sys/class/udc/ should name a controller after boot. The USB hub")
    print("  add-on must come off that port -- it and the gadget want the same")
    print("  connector.")


if __name__ == "__main__":
    # Piping into head is a normal way to use this; do not spew a traceback.
    import signal
    try:
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    except (AttributeError, ValueError):
        pass
    main()
