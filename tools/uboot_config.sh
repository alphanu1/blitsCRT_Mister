#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Put our boot command into u-boot's config, so a bootloader built from source
# already knows how to start BlitsCRT and a fresh card needs no serial import.
#
# This sets CONFIG_BOOTCOMMAND rather than using CONFIG_USE_DEFAULT_ENV_FILE.
# Both work, but the env-file route runs the whole file through xxd, which comes
# from vim on most distributions -- an odd thing to require of a build host, and
# it fails inside u-boot's Makefile with no hint that a package is missing.
# CONFIG_BOOTCOMMAND is an ordinary Kconfig string and needs nothing extra.
#
# The cost is that everything has to be one command rather than a set of
# variables, so tools/uboot_env.txt inlines what blitsenv.txt keeps separate.
# A saved environment still overrides this, which is correct: someone who has
# changed theirs on purpose keeps it.
set -eu

UB="${1:?usage: uboot_config.sh <u-boot-dir> <env-file>}"
ENVF="${2:?usage: uboot_config.sh <u-boot-dir> <env-file>}"
CFG="$UB/.config"

[ -f "$CFG" ]  || { echo "no $CFG -- run the defconfig first" >&2; exit 1; }
[ -f "$ENVF" ] || { echo "no $ENVF" >&2; exit 1; }

# One line, comments and blanks dropped. bootdelay is separate; everything else
# is the boot command.
DELAY=$(sed -n 's/^bootdelay=//p' "$ENVF" | head -1)
CMD=$(sed -n 's/^bootcmd=//p' "$ENVF" | head -1)

[ -n "$CMD" ] || { echo "no bootcmd= line in $ENVF" >&2; exit 1; }

# Only bootcmd is compiled in, so it cannot call `run <something>`: the variable
# it names would not exist and the boot would stop there. Caught here rather than
# on hardware, where it looks like a bootloader that hangs.
case "$CMD" in
*"run "*)
    echo "$ENVF: bootcmd calls 'run', but only bootcmd is compiled in." >&2
    echo "  The variable it names will not exist. Inline it instead." >&2
    exit 1 ;;
esac

set_cfg() {
    sed -i "/^# *$1 is not set\$/d; /^$1=/d" "$CFG"
    printf '%s=%s\n' "$1" "$2" >> "$CFG"
}

# The command contains semicolons, spaces and ${} -- all fine inside a Kconfig
# string, but the quotes have to survive being written into .config.
set_cfg CONFIG_USE_BOOTCOMMAND y
set_cfg CONFIG_BOOTCOMMAND "\"$CMD\""
[ -n "$DELAY" ] && set_cfg CONFIG_BOOTDELAY "$DELAY"

# Quiet. Building kconfig on a modern host emits a page of warnings about u-boot's
# own 2018 sources, three times over, and a real error is invisible in the middle
# of it. Failures still surface: the exit status is checked below.
make -C "$UB" ARCH=arm olddefconfig >/dev/null 2>&1

# Confirm it survived olddefconfig rather than assuming: a symbol that depends on
# something unset is silently dropped, and the failure would only show on
# hardware, as a board that boots to a u-boot prompt.
if grep -q "^CONFIG_BOOTCOMMAND=" "$CFG"; then
    echo "  boot command compiled in; a fresh card needs no serial import"
elif HDR="$UB/include/configs/$(sed -n 's/^CONFIG_SYS_CONFIG_NAME="\(.*\)"$/\1/p' "$CFG" | head -1).h" &&
     [ -f "$HDR" ] &&
     python3 "$(dirname "$0")/uboot_patch_header.py" "$HDR" "$CMD" >/dev/null; then
    # Older u-boot keeps the boot command as a #define rather than in Kconfig,
    # so .config cannot carry it and the header has to be edited instead.
    #
    # Which header is named by CONFIG_SYS_CONFIG_NAME in .config, not by
    # searching include/configs for the first file that happens to define
    # CONFIG_BOOTCOMMAND -- dozens do, one per board, and a search patched
    # mx25pdk.h while leaving the one this build actually uses alone.
    echo "  boot command patched into $(basename "$HDR")"
    echo "  (this u-boot keeps it in a board header, not in Kconfig)"
else
    # Older u-boot keeps the boot command in a board header rather than in
    # Kconfig, so olddefconfig drops the symbol. MiSTer's tree is from 2018 and
    # may well be one of those.
    #
    # Not fatal. The bootloader still works, it just starts with its own default
    # environment, and the card needs the one-time import that
    # docs/UBOOT_ENV.md describes. Better to say so than to fail a build over
    # something that only costs a serial console once.
    echo ""
    echo "  NOTE: this u-boot has no CONFIG_BOOTCOMMAND in Kconfig, so the boot"
    echo "  command could not be compiled in. The bootloader is fine; a card"
    echo "  written from it will stop in u-boot's own default environment."
    echo ""
    echo "  Import ours once per board -- docs/UBOOT_ENV.md. blitsenv.txt is"
    echo "  already on the FAT partition of any image built here."
    echo ""
fi
