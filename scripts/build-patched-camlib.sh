#!/usr/bin/env bash
# Build a patched ptp2.so camlib matching the installed Homebrew libgphoto2.
#
# Why: libgphoto2 (2.5.34, and master as of 2026-07) mis-decodes Canon's EOS
# ImageFormat property on bodies that use the user/custom JPEG compression
# scheme (e.g. the EOS R5): the "RAW + L" and "cRAW + L" combos collapse into
# plain "RAW"/"cRAW", so they vanish from the Format menu and the current
# value reads back wrong. patches/eos-imageformat-L-combos.diff fixes the
# decode; this script downloads the matching libgphoto2 source, applies the
# patch, builds only the ptp2 camlib, and installs it at
#
#     vendor/camlibs/<libgphoto2-version>/ptp2.so
#
# scripts/bundle.sh prefers that file over the stock brew camlib when the
# versions match (native builds only; compat/universal builds keep stock).
# If brew upgrades libgphoto2 to a new version, the vendored camlib no longer
# matches and is silently skipped — re-run this script to rebuild it.
#
# The produced .so is relinked against brew's own libgphoto2 dylibs, so it is
# a drop-in replacement for the stock camlib everywhere brew's library runs.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO="$PWD"
PATCH="$REPO/patches/eos-imageformat-L-combos.diff"
[[ -f "$PATCH" ]] || { echo "FATAL: $PATCH not found" >&2; exit 1; }

LIBGPHOTO2_PREFIX="$(brew --prefix libgphoto2)"
VERSION="$(basename "$(find "$LIBGPHOTO2_PREFIX/lib/libgphoto2" -mindepth 1 -maxdepth 1 -type d | head -1)")"
[[ -n "$VERSION" ]] || { echo "FATAL: can't determine brew libgphoto2 version" >&2; exit 1; }

WORK="$REPO/.camlib-build"
SRC="$WORK/libgphoto2-$VERSION"
STAGE="$WORK/stage"
OUT="$REPO/vendor/camlibs/$VERSION"
TARBALL="$WORK/libgphoto2-$VERSION.tar.bz2"
URL="https://downloads.sourceforge.net/project/gphoto/libgphoto/$VERSION/libgphoto2-$VERSION.tar.bz2"

mkdir -p "$WORK"

if [[ ! -f "$TARBALL" ]]; then
    echo ">> Downloading libgphoto2 $VERSION source"
    curl -fsSL -o "$TARBALL" "$URL"
fi

echo ">> Extracting fresh source tree"
rm -rf "$SRC" "$STAGE"
tar xjf "$TARBALL" -C "$WORK"

echo ">> Applying $(basename "$PATCH")"
(cd "$SRC" && patch -p1 < "$PATCH")

echo ">> Configuring (ptp2 camlib only)"
(cd "$SRC" && ./configure --prefix="$STAGE" --disable-silent-rules \
    --with-camlibs=ptp2 > "$WORK/configure.log" 2>&1) \
    || { tail -20 "$WORK/configure.log" >&2; exit 1; }

echo ">> Building"
make -C "$SRC" -j"$(sysctl -n hw.ncpu)" > "$WORK/make.log" 2>&1 \
    || { tail -20 "$WORK/make.log" >&2; exit 1; }
make -C "$SRC" install > "$WORK/install.log" 2>&1 \
    || { tail -20 "$WORK/install.log" >&2; exit 1; }

SO="$STAGE/lib/libgphoto2/$VERSION/ptp2.so"
[[ -f "$SO" ]] || { echo "FATAL: build produced no $SO" >&2; exit 1; }

# The freshly-built camlib links the staging copies of libgphoto2/_port.
# Repoint those two deps at brew's dylibs so the camlib is a drop-in for the
# stock one (same version, same ABI); everything else already resolves to brew.
echo ">> Relinking against brew's libgphoto2 dylibs"
otool -L "$SO" | tail -n +2 | awk '{print $1}' | while read -r dep; do
    base="$(basename "$dep")"
    case "$base" in
        libgphoto2.*.dylib|libgphoto2_port.*.dylib)
            if [[ "$dep" != "$LIBGPHOTO2_PREFIX"/* ]]; then
                install_name_tool -change "$dep" "$LIBGPHOTO2_PREFIX/lib/$base" "$SO"
            fi
            ;;
    esac
done
# install_name_tool invalidated the signature; arm64 requires a valid one.
codesign --force --sign - "$SO"

if otool -L "$SO" | tail -n +2 | awk '{print $1}' | grep -q "$WORK"; then
    echo "FATAL: ptp2.so still references the build staging dir:" >&2
    otool -L "$SO" | grep "$WORK" >&2
    exit 1
fi

mkdir -p "$OUT"
cp "$SO" "$OUT/ptp2.so"

echo ""
echo "OK  →  vendor/camlibs/$VERSION/ptp2.so"
echo "    make bundle / make run / make dist now vendor the patched camlib."
echo "    (Re-run this script after a brew upgrade of libgphoto2.)"
