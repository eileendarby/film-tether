#!/usr/bin/env bash
# Fetch + extract OLDER-macOS Homebrew bottles for libgphoto2 and all its
# dependencies into a staging directory, so scripts/bundle.sh (COMPAT_STAGE=...)
# can vendor dylibs that target an older macOS than the build host.
#
# Why: `brew install` only ever gives you the bottle for YOUR macOS. Bottling is
# done per-OS with that OS's deployment target, so a Tahoe (26) host produces
# dylibs with minos 26, which won't load on a friend's macOS 14/15 machine.
# `brew fetch --bottle-tag=<older>` downloads an older bottle without installing.
#
# Usage:
#   scripts/fetch-compat-libs.sh <bottle-tag> [stage-dir]
#   e.g. scripts/fetch-compat-libs.sh arm64_sonoma      # macOS 14, Apple Silicon
#        scripts/fetch-compat-libs.sh arm64_sequoia     # macOS 15, Apple Silicon
#        scripts/fetch-compat-libs.sh sonoma            # macOS 14, Intel
#
# Available tags: brew info --json=v2 libgphoto2 | jq '.formulae[0].bottle.stable.files|keys'
set -euo pipefail

TAG="${1:?usage: fetch-compat-libs.sh <bottle-tag> [stage-dir]}"
STAGE="${2:-.compat-libs/$TAG}"

# ONLY the runtime formulae the slim bundle actually uses, NOT `brew fetch --deps`,
# which drags in the entire tree including BUILD tools (cmake, ninja, python, nasm,
# autoconf…) and the codec pile (gd, avif, aom…) we don't bundle. For ptp2 + usb1
# the complete runtime set is these 6 formulae → the 7 dylibs we vendor:
#   libgphoto2  → libgphoto2.6, libgphoto2_port.12, ptp2.so, usb1.so
#   libexif     → libexif.12
#   libtool     → libltdl.7
#   gettext     → libintl.8
#   jpeg-turbo  → libjpeg.8
#   libusb      → libusb-1.0.0
# Override with COMPAT_FORMULAE="…" if you widen CAMLIBS/IOLIBS in bundle.sh.
COMPAT_FORMULAE="${COMPAT_FORMULAE:-libgphoto2 libexif libtool gettext jpeg-turbo libusb}"

echo ">> Fetching '$TAG' bottles (no install): $COMPAT_FORMULAE"
brew fetch --force --bottle-tag="$TAG" $COMPAT_FORMULAE

rm -rf "$STAGE"
mkdir -p "$STAGE"

echo ">> Extracting bottles into $STAGE"
# Each extracts as <formula>/<version>/{lib,…}; install names use @@HOMEBREW_*@@
# placeholders that bundle.sh rewrites to @rpath / @loader_path.
COUNT=0
for formula in $COMPAT_FORMULAE; do
    CACHE="$(brew --cache --bottle-tag="$TAG" "$formula" 2>/dev/null || true)"
    if [[ -z "$CACHE" || ! -f "$CACHE" ]]; then
        echo "   (no $TAG bottle for $formula, skipping)"
        continue
    fi
    tar xzf "$CACHE" -C "$STAGE"
    COUNT=$((COUNT + 1))
done

DYLIBS="$(find "$STAGE" -name '*.dylib' | wc -l | tr -d ' ')"
echo ">> Staged $COUNT formulae ($DYLIBS dylibs) in $STAGE"
echo ""
echo "   Now bundle with:  COMPAT_STAGE=\"$STAGE\" make bundle"
echo "   or:               make dist-compat TAG=$TAG"
