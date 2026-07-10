#!/usr/bin/env bash
# Assemble Film Tether.app from `swift build` output.
#
# Args: $1 = bundle name (e.g. Film Tether.app)
#       $2 = app name (e.g. Frame)
#       $3 = path to compiled binary
#
# Env:  DEVELOPER_ID, optional codesign identity (default: ad-hoc "-")

set -euo pipefail

BUNDLE="${1:?bundle name required}"
APP="${2:?app name required}"
BINARY="${3:?binary path required}"
IDENTITY="${DEVELOPER_ID:--}"

if [[ ! -x "$BINARY" ]]; then
    echo "error: binary not found at $BINARY" >&2
    echo "       run 'make build' first" >&2
    exit 1
fi

BREW_PREFIX="$(brew --prefix)"
LIBGPHOTO2_PREFIX="$(brew --prefix libgphoto2)"

# Compat mode: COMPAT_STAGE points at a directory of extracted OLDER-macOS
# Homebrew bottles (produced by scripts/fetch-compat-libs.sh). When set, vendor
# the camera dylibs from there instead of the natively-installed brew, so the
# app targets an older macOS than the build host and a friend on an earlier OS
# can run it. Bottle install names carry @@HOMEBREW_PREFIX@@/@@HOMEBREW_CELLAR@@
# placeholders (not real paths), copy_deps resolves them by basename, and the
# install-name rewrites below match the placeholders too.
COMPAT_POOL=""
if [[ -n "${COMPAT_STAGE:-}" ]]; then
    LIBGPHOTO2_PREFIX="$(dirname "$(find "$COMPAT_STAGE/libgphoto2" -mindepth 2 -maxdepth 2 -name lib -type d 2>/dev/null | head -1)")"
    COMPAT_POOL="$(find "$COMPAT_STAGE" -name '*.dylib' 2>/dev/null)"
    [[ -d "$LIBGPHOTO2_PREFIX/lib" ]] || { echo "FATAL: COMPAT_STAGE=$COMPAT_STAGE has no extracted libgphoto2 bottle" >&2; exit 1; }
    echo ">> COMPAT mode: vendoring older-OS bottles from $LIBGPHOTO2_PREFIX"
fi

LIBGPHOTO2_VERSION="$(basename "$(find "$LIBGPHOTO2_PREFIX/lib/libgphoto2" -mindepth 1 -maxdepth 1 -type d | head -1)")"

echo ">> Assembling $BUNDLE (libgphoto2 $LIBGPHOTO2_VERSION)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources/camlibs"
mkdir -p "$BUNDLE/Contents/Resources/iolibs"
mkdir -p "$BUNDLE/Contents/Frameworks"

cp "$BINARY" "$BUNDLE/Contents/MacOS/$APP"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

# Inject a build stamp (git short hash + build time) so the running app can show
# exactly which build it is (window title). Lets us confirm a relaunch picked up
# the latest code instead of running stale.
BUILD_STAMP="$(git rev-parse --short HEAD 2>/dev/null || echo nogit) $(date '+%H:%M:%S')"
/usr/libexec/PlistBuddy -c "Add :BuildStamp string $BUILD_STAMP" "$BUNDLE/Contents/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :BuildStamp $BUILD_STAMP" "$BUNDLE/Contents/Info.plist" 2>/dev/null || true
echo "    build stamp: $BUILD_STAMP"

# Generate the app icon (.icns) from Resources/AppIcon.png on every bundle.
# iconutil + sips are macOS-built-in; no extra deps. Sizes match Apple's
# required .iconset spec, iconutil rejects missing/wrong-sized files.
if [[ -f Resources/AppIcon.png ]]; then
    echo ">> Generating AppIcon.icns from Resources/AppIcon.png"
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size"     Resources/AppIcon.png \
            --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" Resources/AppIcon.png \
            --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
fi

# Copy top-level libgphoto2 dylibs into Frameworks/
for dylib in libgphoto2 libgphoto2_port; do
    src="$(ls "$LIBGPHOTO2_PREFIX/lib/$dylib".*.dylib 2>/dev/null | head -1)"
    if [[ -z "$src" ]]; then
        echo "warning: $dylib not found under $LIBGPHOTO2_PREFIX/lib" >&2
        continue
    fi
    dst="$BUNDLE/Contents/Frameworks/$(basename "$src")"
    cp "$src" "$dst"
    chmod +w "$dst"
done

# Also copy any further deps the dylibs need (libusb, libintl, libiconv, etc.)
copy_deps() {
    local target="$1"
    otool -L "$target" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in
            @@HOMEBREW*|/opt/homebrew/*|/usr/local/Cellar/*|"$BREW_PREFIX"/*)
                base="$(basename "$dep")"
                if [[ ! -f "$BUNDLE/Contents/Frameworks/$base" ]]; then
                    # In compat mode otool reports @@HOMEBREW@@ placeholders, so
                    # resolve by basename from the staged bottle pool; otherwise
                    # copy the real brew path.
                    srcdep="$dep"
                    if [[ -n "$COMPAT_POOL" ]]; then
                        srcdep="$(printf '%s\n' "$COMPAT_POOL" | grep "/$base\$" | head -1)"
                    fi
                    if [[ -z "$srcdep" || ! -f "$srcdep" ]]; then
                        echo "   ! missing dep $base (compat=${COMPAT_POOL:+yes})" >&2
                        continue
                    fi
                    echo "   + $base"
                    cp "$srcdep" "$BUNDLE/Contents/Frameworks/"
                    chmod +w "$BUNDLE/Contents/Frameworks/$base"
                    copy_deps "$BUNDLE/Contents/Frameworks/$base"
                fi
                ;;
        esac
    done
}

echo ">> Vendoring transitive dylib deps"
for f in "$BUNDLE/Contents/Frameworks/"*.dylib; do
    copy_deps "$f"
done

# Copy camlibs, ONLY the ones we need. ptp2.so is the PTP driver and handles
# EVERY Canon EOS body (7D, 70D, 5D, R-series, they all speak PTP), so it alone
# gives full EOS compatibility. The other ~30 camlibs are for NON-EOS gear
# (webcams, photo frames, legacy serial PowerShots via canon.so) and dragged in
# libgd + a pile of image/video codecs (libavif, libaom, libdav1d, libvmaf,
# libwebp, libtiff, libfreetype, …) for toy-camera thumbnailing we never use.
# Whitelisting to ptp2 keeps max EOS support with zero weird deps. Override with
# CAMLIBS="ptp2 …" if you ever need a non-EOS body.
CAMLIBS_WANTED="${CAMLIBS:-ptp2}"
echo ">> Vendoring camlibs: $CAMLIBS_WANTED"
for cam in $CAMLIBS_WANTED; do
    src="$LIBGPHOTO2_PREFIX/lib/libgphoto2/$LIBGPHOTO2_VERSION/$cam.so"
    # Prefer a repo-local patched camlib (built by scripts/build-patched-camlib.sh,
    # e.g. the EOS "RAW + L" ImageFormat decode fix) when its libgphoto2 version
    # matches the one being vendored. Native builds only: compat/universal
    # builds target other OS/arch bottles the local build doesn't match.
    patched="vendor/camlibs/$LIBGPHOTO2_VERSION/$cam.so"
    if [[ -z "${COMPAT_STAGE:-}" && -f "$patched" ]]; then
        echo "   using patched $cam.so from $patched"
        src="$patched"
    fi
    if [[ -f "$src" ]]; then
        cp "$src" "$BUNDLE/Contents/Resources/camlibs/"
    else
        echo "warning: camlib $cam.so not found at $src" >&2
    fi
done

# Copy iolibs, ONLY usb1 (USB transport; every EOS body here is USB-tethered).
# disk/ptpip/serial are unused. Override with IOLIBS="usb1 ptpip" if needed.
IOLIBS_WANTED="${IOLIBS:-usb1}"
echo ">> Vendoring iolibs: $IOLIBS_WANTED"
PORT_VERSION_DIR="$(find "$LIBGPHOTO2_PREFIX/lib/libgphoto2_port" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)"
if [[ -n "$PORT_VERSION_DIR" ]]; then
    for io in $IOLIBS_WANTED; do
        src="$PORT_VERSION_DIR/$io.so"
        if [[ -f "$src" ]]; then
            cp "$src" "$BUNDLE/Contents/Resources/iolibs/"
        else
            echo "warning: iolib $io.so not found at $src" >&2
        fi
    done
fi

# The camlibs/iolibs (.so) are dlopen'd at runtime and have their OWN brew-path
# dependencies (libgphoto2, libgphoto2_port, libexif, libusb, ...). Vendor any
# that the top-level sweep missed, so nothing the camlib needs resolves back to
# /usr/local at runtime (which would load a SECOND copy of libgphoto2_port, a
# separate gp_log_add_func registry, and break self-containment on a brew-less Mac).
echo ">> Vendoring camlib/iolib transitive deps"
for f in "$BUNDLE/Contents/Resources/camlibs/"*.so "$BUNDLE/Contents/Resources/iolibs/"*.so; do
    [[ -f "$f" ]] || continue
    copy_deps "$f"
done

# Strip the inherited Homebrew code signatures BEFORE rewriting install names.
# Homebrew ships its dylibs ad-hoc signed; install_name_tool then floods stderr
# with "changes being made to the file will invalidate the code signature"
# (one line per dylib per change, dozens of them). The signatures are
# meaningless here anyway: we re-sign every embedded binary at the end. Removing
# them first makes install_name_tool silent without hiding real errors (we do
# NOT blanket-suppress its stderr, that masked an -add_rpath failure once).
echo ">> Stripping inherited signatures (re-signed at the end)"
for f in "$BUNDLE/Contents/Frameworks/"*.dylib \
         "$BUNDLE/Contents/Resources/camlibs/"*.so \
         "$BUNDLE/Contents/Resources/iolibs/"*.so; do
    [[ -f "$f" ]] || continue
    codesign --remove-signature "$f" 2>/dev/null || true   # no-op if already unsigned
done

# Rewrite install names to @rpath so the bundled binary finds the bundled dylibs.
# Stop suppressing install_name_tool errors with 2>/dev/null, that masked a
# silent failure where -add_rpath errored because the rpath already existed
# from a prior cycle, leaving the binary unable to find @rpath dylibs at
# launch ("Library not loaded: @rpath/libgphoto2.6.dylib"). Now errors fail
# the build loudly.
echo ">> Rewriting install names to @rpath"
for f in "$BUNDLE/Contents/Frameworks/"*.dylib; do
    base="$(basename "$f")"
    install_name_tool -id "@rpath/$base" "$f"
    otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in
            @@HOMEBREW*|/opt/homebrew/*|/usr/local/Cellar/*|"$BREW_PREFIX"/*)
                depbase="$(basename "$dep")"
                install_name_tool -change "$dep" "@rpath/$depbase" "$f"
                ;;
        esac
    done
done

# And rewrite the main binary's references the same way
for dep in $(otool -L "$BUNDLE/Contents/MacOS/$APP" | tail -n +2 | awk '{print $1}'); do
    case "$dep" in
        @@HOMEBREW*|/opt/homebrew/*|/usr/local/Cellar/*|"$BREW_PREFIX"/*)
            depbase="$(basename "$dep")"
            install_name_tool -change "$dep" "@rpath/$depbase" "$BUNDLE/Contents/MacOS/$APP"
            ;;
    esac
done

# Rewrite camlib/iolib deps to the bundled Frameworks. These .so files live in
# Contents/Resources/{camlibs,iolibs}/ and are dlopen'd by libgphoto2 at runtime;
# @loader_path resolves relative to each .so, so ../../Frameworks reaches the
# bundled dylibs. WITHOUT this the bundled ptp2.so still loaded brew's
# libgphoto2_port (absolute path), a 2nd port-lib copy with a separate
# gp_log_add_func registry, so the app's EVF-record log callback saw nothing,
# and the bundle silently depended on brew. @rpath isn't used here because the
# camlibs carry no LC_RPATH; @loader_path is unconditional.
echo ">> Rewriting camlib/iolib install names to @loader_path/../../Frameworks"
for f in "$BUNDLE/Contents/Resources/camlibs/"*.so "$BUNDLE/Contents/Resources/iolibs/"*.so; do
    [[ -f "$f" ]] || continue
    otool -L "$f" | tail -n +2 | awk '{print $1}' | while read -r dep; do
        case "$dep" in
            @@HOMEBREW*|/opt/homebrew/*|/usr/local/Cellar/*|"$BREW_PREFIX"/*)
                depbase="$(basename "$dep")"
                install_name_tool -change "$dep" "@loader_path/../../Frameworks/$depbase" "$f"
                ;;
        esac
    done
done

# Verify NO camlib/iolib still references brew, a leftover absolute path means a
# second dylib copy at runtime (the bug this fixes). Fail loudly if so.
for f in "$BUNDLE/Contents/Resources/camlibs/"*.so "$BUNDLE/Contents/Resources/iolibs/"*.so; do
    [[ -f "$f" ]] || continue
    if otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -qE '^/opt/homebrew/|^/usr/local/Cellar/|^@@HOMEBREW'; then
        echo "FATAL: $(basename "$f") still links a brew/placeholder path, would load a 2nd libgphoto2_port copy" >&2
        otool -L "$f" | grep -E '/opt/homebrew/|/usr/local/Cellar/|@@HOMEBREW' >&2
        exit 1
    fi
done

# Tell the executable to look in Contents/Frameworks.
# install_name_tool -add_rpath errors out if the rpath ALREADY exists in the
# binary's load commands (common after a re-bundle). Check first via otool;
# only add if missing. This makes the script idempotent across re-bundles
# instead of silently leaving the binary without the rpath.
RPATH="@executable_path/../Frameworks"
if otool -l "$BUNDLE/Contents/MacOS/$APP" | grep -A 2 "LC_RPATH" | grep -q "path $RPATH "; then
    echo "   rpath '$RPATH' already present, skipping add_rpath"
else
    install_name_tool -add_rpath "$RPATH" "$BUNDLE/Contents/MacOS/$APP"
    echo "   added rpath '$RPATH' to binary"
fi

# Verify the binary actually links to @rpath/libgphoto2.6.dylib AND that the
# rpath is in place. If either is missing, the app won't launch, fail loudly
# here so we don't ship a bundle that dyld will reject.
if ! otool -L "$BUNDLE/Contents/MacOS/$APP" | grep -q "@rpath/libgphoto2"; then
    echo "FATAL: binary doesn't reference @rpath/libgphoto2, dyld will fail at launch" >&2
    otool -L "$BUNDLE/Contents/MacOS/$APP" | head -20 >&2
    exit 1
fi
if ! otool -l "$BUNDLE/Contents/MacOS/$APP" | grep -A 2 "LC_RPATH" | grep -q "path $RPATH "; then
    echo "FATAL: binary missing LC_RPATH $RPATH, dyld can't find bundled dylibs" >&2
    exit 1
fi

# Codesign, sign embedded dylibs first, then the bundle.
# macOS Sequoia's codesign hits "internal error in Code Signing subsystem"
# intermittently when signing many files in rapid succession (looks like a
# race in CSCommon's database lock). Retry up to 3× per file with a small
# backoff; the failure is almost always transient.
codesign_one() {
    local f="$1"
    for attempt in 1 2 3; do
        if codesign --force --sign "$IDENTITY" "$f" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    # One last attempt with stderr visible so we see the real error if it
    # keeps failing.
    codesign --force --sign "$IDENTITY" "$f"
}

echo ">> Codesigning ($IDENTITY)"
for f in "$BUNDLE/Contents/Frameworks/"*.dylib \
         "$BUNDLE/Contents/Resources/camlibs/"*.so \
         "$BUNDLE/Contents/Resources/iolibs/"*.so; do
    [[ -f "$f" ]] || continue
    codesign_one "$f"
done
# --deep is deprecated; inner binaries were signed individually above.
# Bundle-level sign also gets the retry wrapper since it can hit the same
# transient race.
bundle_sign() {
    for attempt in 1 2 3; do
        if codesign --force --sign "$IDENTITY" \
            --entitlements "Resources/${APP}.entitlements" \
            "$BUNDLE" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    codesign --force --sign "$IDENTITY" \
        --entitlements "Resources/${APP}.entitlements" \
        "$BUNDLE"
}
bundle_sign

# Quick sanity probe
echo ">> Verifying"
file "$BUNDLE/Contents/MacOS/$APP" | head -1
codesign --verify --verbose "$BUNDLE" 2>&1 | head -3

echo ""
echo "OK  →  $BUNDLE"
