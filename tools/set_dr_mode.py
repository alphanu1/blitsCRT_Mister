#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Patch the HPS OTG controller in a built device tree for gadget mode.

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

# Gadget-mode FIFO split, in 32-bit words out of the 8064 the core reports.
#
# The stock socfpga node sets none of these: it was written for host mode, where
# they are unused. In gadget mode dwc2 falls back to defaults that can leave a
# bulk endpoint enabled with no usable FIFO behind it -- and the symptom is not
# an error but silence, because an endpoint with nowhere to put data NAKs
# forever rather than stalling. Control transfers keep working throughout, since
# ep0 is budgeted separately, so enumeration and the whole protocol succeed while
# bulk never moves a byte.
#
# One bulk OUT endpoint is all this device has, so the RX side gets the room --
# and it needs a great deal more of it than the first guess allowed.
#
# 512 words is 2048 bytes: four 512-byte packets of buffering for a sustained
# bulk stream. When it fills, the controller NAKs until the daemon drains it, and
# every NAK costs a microframe. Measured effect: 614400 bytes took 28.6 ms, which
# is 21.5 MB/s against the 35-40 a high-speed bulk endpoint should manage. No
# errors, no stalls, just half rate -- the hardest kind of problem to see.
#
# 4096 words is 16 KB, thirty-two packets, and the core has 8064 words to hand
# out. Using 6272 of them leaves the transmit side untouched and still has room
# spare. There is no reason to be frugal here: nothing else on this device needs
# the space.
FIFOS = {
    "g-rx-fifo-size": 4096,
    "g-np-tx-fifo-size": 256,
}

# One TX FIFO size per IN endpoint, and dwc2 wants an entry for *every* endpoint
# the core has, not just the ones in use. This core reports 16 EPs, so 15 entries
# for EP1..EP15; leaving the tail at zero is rejected outright:
#
#   dwc2_check_param_tx_fifo_sizes: Invalid parameter g_tx_fifo_size[5]=0
#
# This device has one bulk OUT endpoint and no IN endpoints beyond ep0, so these
# are almost all unused -- they simply have to be valid. 15 x 128 = 1920 words,
# plus 512 + 256, against the 8064 the core reports. Room to spare.
FIFO_TX = [128] * 15


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

        # FIFO sizes first, so dr_mode stays the last thing added and the node
        # reads in a sensible order.
        #
        # Replace rather than skip when a property is already there. Skipping is
        # how a dtb patched by an older version of this script keeps its stale
        # values while the run reports success -- which cost a boot: a four-entry
        # g-tx-fifo-size stayed in place and dwc2 went on rejecting it.
        def setprop(blob, prop, text, shown):
            pat = r'[ \t]*\b%s\s*=[^;]*;\n?' % re.escape(prop)
            m = re.search(pat, blob)
            if m:
                # dtc prints numbers in hex, so compare the values rather than
                # the text; otherwise every run claims to have replaced
                # something it did not.
                had = [int(x, 0) for x in re.findall(r'0x[0-9a-fA-F]+|\d+',
                                                     m.group(0).split("=", 1)[1])]
                new_vals = [int(x, 0) for x in re.findall(r'0x[0-9a-fA-F]+|\d+',
                                                          text)]
                if had == new_vals:
                    return blob, None          # already exactly right
                blob = re.sub(pat, "", blob, count=1)
                note = "%s %d entries -> %d" % (prop, len(had), len(new_vals)) \
                       if len(had) != len(new_vals) else \
                       "%s replaced -> %s" % (prop, shown)
            else:
                note = "%s = %s" % (prop, shown)
            blob = blob.replace("{", "{\n%s%s = %s;" % (indent, prop, text), 1)
            return blob, note

        for prop, val in FIFOS.items():
            blob, note = setprop(blob, prop, "<%d>" % val, str(val))
            if note:
                touched.append((addr, note))

        vals = " ".join(str(v) for v in FIFO_TX)
        blob, note = setprop(blob, "g-tx-fifo-size", "<%s>" % vals,
                             "%d entries" % len(FIFO_TX))
        if note:
            touched.append((addr, note))

        cur = re.search(r'dr_mode\s*=\s*"([^"]+)"', blob)
        if cur:
            if cur.group(1) == WANT:
                touched.append((addr, "dr_mode already " + WANT))
            else:
                blob = re.sub(r'dr_mode\s*=\s*"[^"]+"',
                              'dr_mode = "%s"' % WANT, blob, count=1)
                touched.append((addr, "dr_mode %s -> %s" % (cur.group(1), WANT)))
        else:
            # No dr_mode at all: add one just inside the node.
            blob = blob.replace("{", '{\n%sdr_mode = "%s";' % (indent, WANT), 1)
            touched.append((addr, "dr_mode unset -> %s" % WANT))

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
        print("  usb@%s: %s" % (addr, what))
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
