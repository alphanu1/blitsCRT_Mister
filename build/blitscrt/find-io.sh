#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Find which HPS GPIO line a button is on, by pressing it and seeing what moved.
#
# Written while working out why the I/O board buttons did nothing, and kept
# because the elimination is worth repeating on another board.
#
# The answer, for a MiSTer Pi with the newer A/V board: the buttons are behind an
# MCP23009 I2C expander on a bus bit-banged in the fabric, and the LED pins carry
# video for the board's DAC. Neither is on an HPS GPIO, which is what this
# script scans -- so on that hardware it correctly finds nothing, and that result
# is what ruled the HPS out. See M6 in the README.
#
# This reads every HPS GPIO line, waits for a press, and reports what changed.
#
# Result on a MiSTer Pi: nothing changes. All 85 lines were read bar three, which
# debugfs names as i2c_gpio and hps_led0.
#
# Usage:
#   tools/find-io.sh            snapshot, prompt, compare
#   tools/find-io.sh leds       walk every line, briefly, watching for a light
#
# Nothing here is destructive in the first mode -- it only reads. The second mode
# drives lines, which is why it is not the default: driving a line that is wired
# to something other than an LED is how a GPIO gets damaged.

set -u

SYS=/sys/class/gpio

# Somewhere to write. The initramfs has no /tmp, so fall back to the card, which
# is always mounted by the time a shell exists.
for d in /tmp /media/fat /root .; do
    if mkdir -p "$d" 2>/dev/null && : > "$d/.iotest" 2>/dev/null; then
        rm -f "$d/.iotest"
        WORK="$d"
        break
    fi
done
if [ -z "${WORK:-}" ]; then
    echo "find-io: nowhere writable to work in" >&2
    exit 1
fi

lines() {
    for chip in "$SYS"/gpiochip*; do
        [ -d "$chip" ] || continue
        base=$(cat "$chip/base")
        n=$(cat "$chip/ngpio")
        i=0
        while [ "$i" -lt "$n" ]; do
            echo $((base + i))
            i=$((i + 1))
        done
    done
}

snapshot() {
    for g in $(lines); do
        [ -d "$SYS/gpio$g" ] || echo "$g" > "$SYS/export" 2>/dev/null
        v=$(cat "$SYS/gpio$g/value" 2>/dev/null) || continue
        echo "$g $v"
    done
}

# Which lines could not be read, and how many the chips claim to have. A line
# that will not export is one a driver has taken, and that is as interesting as
# one that moves -- a button whose line is claimed would never show up in the
# comparison at all.
unreadable() {
    total=0
    for chip in "$SYS"/gpiochip*; do
        [ -d "$chip" ] || continue
        n=$(cat "$chip/ngpio")
        b=$(cat "$chip/base")
        total=$((total + n))
        echo "  chip at base $b: $n lines" >&2
    done
    echo "  $total lines in total" >&2
    for g in $(lines); do
        [ -d "$SYS/gpio$g" ] || echo "$g" > "$SYS/export" 2>/dev/null
        cat "$SYS/gpio$g/value" >/dev/null 2>&1 || echo "$g"
    done
}

case "${1:-watch}" in
watch)
    echo "Reading every HPS GPIO line. Lines already claimed by a driver will"
    echo "be skipped -- that is normal and not an error."
    echo ""
    snapshot > "$WORK/gpio.before"
    n=$(wc -l < "$WORK/gpio.before")
    echo "Read $n lines into $WORK."
    # debugfs names whoever holds a line, and is not mounted by default.
    [ -r /sys/kernel/debug/gpio ] ||
        mount -t debugfs none /sys/kernel/debug 2>/dev/null

    echo ""
    echo "Lines that could not be read (claimed by a driver):"
    u=$(unreadable)
    if [ -n "$u" ]; then
        for g in $u; do
            owner=""
            [ -r /sys/kernel/debug/gpio ] &&
                owner=$(grep -w "gpio-$g" /sys/kernel/debug/gpio 2>/dev/null)
            echo "  $g ${owner:+-- $owner}"
        done
    else
        echo "  none"
    fi
    echo ""

    if [ "$n" -eq 0 ]; then
        echo ""
        echo "No GPIO lines could be read at all. Either sysfs GPIO is not"
        echo "enabled in the kernel, or every line is claimed by a driver."
        echo "Check: ls /sys/class/gpio/"
        exit 1
    fi
    echo ""
    echo "Now HOLD a button down, and press Enter while still holding it."
    read _dummy
    snapshot > "$WORK/gpio.after"

    echo ""
    # Compared here rather than with diff: busybox's returns non-zero for
    # reasons of its own and produced an empty "these lines changed" list.
    awk 'NR==FNR { was[$1] = $2; next }
         ($1 in was) && (was[$1] != $2) {
             printf "  line %s: %s -> %s\n", $1, was[$1], $2; found++
         }
         END { exit(found ? 0 : 1) }' \
        "$WORK/gpio.before" "$WORK/gpio.after" > "$WORK/gpio.diff"
    changed=$?

    if [ "$changed" -eq 0 ]; then
        echo "These lines changed while the button was held:"
        echo ""
        cat "$WORK/gpio.diff"
        echo ""
        echo "A button reads 1 released and 0 held, so 1 -> 0 is the one."
    else
        echo "Nothing changed."
        echo ""
        echo "Either the button is not on an HPS GPIO, or its line is one of the"
        echo "claimed ones listed above and could not be read. If the fabric"
        echo "cannot see it either -- blitscrt-peek -i -- then it is on neither."
    fi
    ;;

leds)
    echo "This drives every readable GPIO low for a moment, one at a time,"
    echo "watching for something to light."
    echo ""
    echo "It can damage a pin wired to an output. Do not run it on a board you"
    echo "care about without knowing what is on these lines."
    echo ""
    printf "Type YES to continue: "
    read ans
    [ "$ans" = "YES" ] || { echo "stopped"; exit 1; }

    for g in $(lines); do
        [ -d "$SYS/gpio$g" ] || echo "$g" > "$SYS/export" 2>/dev/null
        [ -w "$SYS/gpio$g/direction" ] || continue
        echo out > "$SYS/gpio$g/direction" 2>/dev/null || continue
        echo "  line $g low"
        echo 0 > "$SYS/gpio$g/value" 2>/dev/null
        sleep 1
        echo 1 > "$SYS/gpio$g/value" 2>/dev/null
        echo in > "$SYS/gpio$g/direction" 2>/dev/null
    done
    ;;

*)
    echo "usage: $0 [watch|leds]" >&2
    exit 2
    ;;
esac
