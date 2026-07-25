#!/bin/sh
# get-toolchain.sh -- download and extract a prebuilt ARM cross-compiler.
#
# Deliberately separate from setup-deps.sh and opt-in: it pulls ~150 MB from a
# third-party server (Bootlin) and drops a toolchain on disk, which should be a
# choice you make on purpose, not a side effect of installing packages.
#
# It fetches the Bootlin armv7-eabihf glibc *stable* toolchain -- prebuilt, no
# compilation. Stable rather than bleeding-edge because its older kernel headers
# are the safer match for the MiSTer SoC kernel: the toolchain's headers version
# must be <= the kernel you build against.
#
# The triplet the binaries use is arm-buildroot-linux-gnueabihf-. After this
# runs, either add the printed bin/ to PATH, or pass CROSS_COMPILE to make.

set -eu

# Pinned release. Bump the version and its sha together; get the sha from the
# .sha256 link next to the tarball on toolchains.bootlin.com.
VERSION="armv7-eabihf--glibc--stable-2024.02-1"
BASE="https://toolchains.bootlin.com/downloads/releases/toolchains/armv7-eabihf/tarballs"
TARBALL="$VERSION.tar.bz2"
URL="$BASE/$TARBALL"
SHA_URL="$BASE/$VERSION.sha256"

# Where it lands. Override with TOOLCHAIN_DIR=...
DEST="${TOOLCHAIN_DIR:-$HOME/toolchains}"
TRIPLET="arm-buildroot-linux-gnueabihf-"

echo "toolchain: $VERSION"
echo "target:    $DEST/$VERSION"
echo ""

if [ -x "$DEST/$VERSION/bin/${TRIPLET}gcc" ]; then
    echo "already present. nothing to download."
    BINDIR="$DEST/$VERSION/bin"
else
    # need a downloader
    DL=""
    if command -v curl >/dev/null 2>&1; then DL="curl"; \
    elif command -v wget >/dev/null 2>&1; then DL="wget"; \
    else echo "need curl or wget to download."; exit 1; fi

    mkdir -p "$DEST"
    cd "$DEST"

    echo "downloading $TARBALL ..."
    if [ "$DL" = "curl" ]; then
        curl -fL -o "$TARBALL" "$URL"
        curl -fsSL -o "$TARBALL.sha256" "$SHA_URL" || true
    else
        wget -O "$TARBALL" "$URL"
        wget -q -O "$TARBALL.sha256" "$SHA_URL" || true
    fi

    # verify the checksum if we got the .sha256 and a sha tool
    if [ -s "$TARBALL.sha256" ] && command -v sha256sum >/dev/null 2>&1; then
        echo "verifying checksum ..."
        # the .sha256 file lists the hash and a path; normalise to our filename
        want=$(awk '{print $1}' "$TARBALL.sha256")
        got=$(sha256sum "$TARBALL" | awk '{print $1}')
        if [ "$want" != "$got" ]; then
            echo "CHECKSUM MISMATCH -- refusing to extract."
            echo "  want $want"
            echo "  got  $got"
            exit 1
        fi
        echo "checksum ok."
    else
        echo "note: could not verify checksum (no .sha256 or sha256sum)."
    fi

    echo "extracting ..."
    tar xf "$TARBALL"
    rm -f "$TARBALL" "$TARBALL.sha256"
    BINDIR="$DEST/$VERSION/bin"
fi

echo ""
if [ -x "$BINDIR/${TRIPLET}gcc" ]; then
    echo "installed. the compiler is:"
    echo "  $BINDIR/${TRIPLET}gcc"
    echo ""
    echo "use it one of two ways:"
    echo "  1. add it to PATH for this shell:"
    echo "       export PATH=\"$BINDIR:\$PATH\""
    echo "     (add that line to ~/.bashrc or ~/.zshrc to make it stick)"
    echo "  2. or pass it to make each time:"
    echo "       make world CROSS_COMPILE=$TRIPLET"
    echo ""
    echo "then 'make world' builds the kernel. it auto-detects the compiler once"
    echo "it is on PATH."
else
    echo "something went wrong: no ${TRIPLET}gcc under $BINDIR"
    exit 1
fi
