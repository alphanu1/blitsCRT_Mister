#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# blitscrt-startup.sh -- run blitscrtd on MiSTer's own Linux.
#
# Install: copy blitscrtd and this script into the same folder on the card
# (normally /media/fat/linux/). Rename any _user-startup.sh to user-startup.sh
# and add:
#     sh /media/fat/linux/blitscrt-startup.sh &
#
# Paths are derived from this script's own location, so it works wherever it is
# placed -- nothing is hardcoded. The log and the daemon are looked for next to
# this script.

DIR="$(dirname "$0")"
DAEMON="$DIR/blitscrtd"
LOG="$DIR/blitscrtd.log"

chmod +x "$DAEMON" 2>/dev/null || true

# Stamp each launch so a re-run (e.g. after the warm reboot when a core is
# selected) is visible in the log, and we can tell which invocation is talking
# to our loaded core versus the menu.
{
  echo "blitscrt: starting $DAEMON"
  echo "blitscrt: uptime $(cat /proc/uptime 2>/dev/null | cut -d. -f1)s, $(date 2>/dev/null)"
} > "$LOG"
"$DAEMON" --no-gadget >> "$LOG" 2>&1 &
