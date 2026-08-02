#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# setup-deps.sh -- install the build dependencies for blitsCRT_Mister.
#
# Two groups, installed separately so a hiccup in one does not abort the other:
#
#   repo tools   iverilog, Pillow, dtc, git, and mtools/dosfstools/sfdisk for
#                `make image`, and bison/flex/bc for `make uboot` -- all in
#                the official repos on
#                every supported distro. Installed in one transaction.
#
#   cross gcc    the ARM Linux cross-compiler. This is the awkward one: it is
#                NOT in Arch's official repos (it lives in the AUR), while
#                Debian/Fedora/openSUSE do ship it. Handled per distro, and a
#                failure here never touches the repo-tools install.
#
# Not installed, because neither is a package: Quartus Prime Lite (a manual
# licensed download) and the kernel tree (offered as a clone at the end).
#
# Pass --dry-run to print the commands without running them.

set -eu

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

run() {
    echo "  \$ $*"
    [ "$DRY" -eq 1 ] || "$@"
}

# ---- detect the package manager ----
PM=""
for c in pacman apt dnf zypper; do
    if command -v "$c" >/dev/null 2>&1; then PM="$c"; break; fi
done

if [ -z "$PM" ]; then
    echo "No supported package manager found (pacman, apt, dnf, zypper)."
    echo "Install by hand: iverilog, python Pillow, dtc, git, mtools, dosfstools,"
    echo "bison, flex, bc, openssl headers, and an ARM Linux"
    echo "cross-compiler (arm-linux-gnueabihf-gcc)."
    exit 1
fi

echo "package manager: $PM"
[ "$DRY" -eq 1 ] && echo "(dry run, nothing will be installed)"
echo ""

# ---- repo tools: names and install command per manager ----
case "$PM" in
    pacman)
        REPO="iverilog python-pillow dtc git mtools dosfstools util-linux bison flex bc openssl"
        REPO_INSTALL="sudo pacman -S --needed"
        ;;
    apt)
        REPO="iverilog python3-pil device-tree-compiler git mtools dosfstools fdisk bison flex bc libssl-dev"
        REPO_INSTALL="sudo apt install -y"
        ;;
    dnf)
        REPO="iverilog python3-pillow dtc git mtools dosfstools util-linux bison flex bc openssl"
        REPO_INSTALL="sudo dnf install -y"
        ;;
    zypper)
        REPO="iverilog python3-Pillow dtc git mtools dosfstools util-linux bison flex bc openssl"
        REPO_INSTALL="sudo zypper install -y"
        ;;
esac

echo "repo tools: $REPO"
run $REPO_INSTALL $REPO || \
  echo "  some repo tools did not install; check names for your distro."
echo ""

# ---- ARM Linux cross-compiler, handled per distro ----
echo "ARM cross-compiler:"
case "$PM" in
    pacman)
        # Arch does not ship an ARM Linux cross-compiler in the official repos.
        # The AUR package builds the whole toolchain from source (gcc, glibc,
        # binutils) -- slow and fragile. A prebuilt toolchain is far better:
        # extract a tarball, put its bin/ on PATH, done. This script does not
        # download it automatically (it is a large binary from a third party),
        # but it tells you exactly where to get one.
        echo "  Arch has no ARM Linux cross-compiler in the official repos."
        echo "  Do NOT use the AUR package unless you want an hour-long source"
        echo "  build. Grab a prebuilt toolchain instead:"
        echo ""
        echo "    Arm:     https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads"
        echo "             pick 'AArch32 target with hard float' (arm-none-linux-gnueabihf)"
        echo "    Bootlin: https://toolchains.bootlin.com  (armv7-eabihf, glibc)"
        echo ""
        echo "  extract it, add its bin/ to PATH, then build with:"
        echo "    make world CROSS_COMPILE=arm-none-linux-gnueabihf-"
        echo ""
        echo "  the kernel step is skipped until a cross-compiler is on PATH;"
        echo "  the fabric build does not need one."
        ;;
    apt)
        run sudo apt install -y gcc-arm-linux-gnueabihf || \
          echo "  cross-compiler install did not complete; kernel step will skip."
        ;;
    dnf)
        run sudo dnf install -y gcc-arm-linux-gnu || \
          echo "  cross-compiler install did not complete; kernel step will skip."
        ;;
    zypper)
        run sudo zypper install -y cross-arm-linux-gnueabihf-gcc || \
          echo "  cross-compiler install did not complete; kernel step will skip."
        ;;
esac
echo ""

# ---- report what the build will now find ----
echo "checking the toolchain:"
for tool in iverilog dtc git; do
    if command -v "$tool" >/dev/null 2>&1; then
        echo "  ok    $tool"
    else
        echo "  MISS  $tool"
    fi
done
if python3 -c "import PIL" >/dev/null 2>&1; then
    echo "  ok    python pillow"
else
    echo "  MISS  python pillow"
fi
CC=""
for c in arm-linux-gnueabihf-gcc arm-none-linux-gnueabihf-gcc arm-linux-gnueabi-gcc; do
    command -v "$c" >/dev/null 2>&1 && { CC="$c"; break; }
done
if [ -n "$CC" ]; then
    echo "  ok    cross-compiler ($CC)"
else
    echo "  MISS  ARM cross-compiler (kernel build will be skipped)"
fi

echo ""
echo "still needed, by hand:"
echo "  - Quartus Prime Lite, with the Cyclone V device family ticked."
echo "    Builds the bitstream. See 'Prerequisites' in the README."
echo "  - a kernel tree, if you want to build the custom kernel image."

# ---- offer to clone a kernel tree ----
echo ""
DEST="$HOME/source"
if [ -d "$DEST/Linux-Kernel_MiSTer" ] || [ -d "$DEST/linux-socfpga" ]; then
    echo "a kernel tree already exists under $DEST -- leaving it alone."
else
    printf "clone the MiSTer kernel tree into %s? [Y/n] " "$DEST"
    if [ "$DRY" -eq 1 ]; then
        echo "(dry run)"
    else
        read -r reply
        case "$reply" in
            [Nn]*)
                echo "skipped. run 'make kernel-clone' later, or set KERNEL_SRC=."
                ;;
            *)
                mkdir -p "$DEST"
                run git clone --depth 1 \
                    https://github.com/MiSTer-devel/Linux-Kernel_MiSTer.git \
                    "$DEST/Linux-Kernel_MiSTer"
                echo ""
                echo "cloned. 'make world' auto-detects it and picks the"
                echo "MiSTer defconfig and dtb automatically."
                ;;
        esac
    fi
fi

# --- the two cross-compilers -------------------------------------------------
#
# The kernel and daemon want a current one. MiSTer's u-boot is a 2017 tree and
# wants gcc 4 or 5 -- built with anything newer its SPL hangs at its own banner.
# Both are fetched by `make get-toolchain`; offer it here so a fresh clone needs
# one command rather than three.
echo ""
if [ -z "${BLITSCRT_NO_TOOLCHAIN:-}" ]; then
    printf "Fetch the ARM cross-compilers now? Needed for the kernel, the daemon\nand the bootloader. [Y/n] "
    read -r reply || reply=n
    case "$reply" in
    [Nn]*) echo "skipped -- 'make get-toolchain' when you want them." ;;
    *)     make -C "$(dirname "$0")/.." get-toolchain || \
             echo "toolchain fetch failed -- 'make get-toolchain' to retry." ;;
    esac
fi

echo ""
echo "done. run 'make tools' to see what the build detects, then 'make world'."
echo ""
echo "'make world' now builds everything it can and, if the bitstream, the"
echo "kernel and a bootloader are all present, writes a card image."
