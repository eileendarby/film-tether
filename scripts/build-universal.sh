#!/usr/bin/env bash
# Build a UNIVERSAL (arm64 + x86_64) Film Tether targeting macOS Sonoma (14)+,
# ENTIRELY on an Intel host, no Apple Silicon machine needed. Homebrew bottles
# are downloadable pre-builts for any arch/OS, so we fetch both the `sonoma`
# (x86_64) and `arm64_sonoma` libgphoto2 bottle sets, build each arch slice
# against its own bottle, bundle each separately (reusing the proven
# scripts/bundle.sh + COMPAT_STAGE path → @rpath install names), then lipo-merge
# the two finished bundles into one universal .app.
#
# Output: "Film Tether.app" that runs native on Intel + Apple Silicon, macOS 14+.
#
# Env: DEVELOPER_ID, optional "Developer ID Application: NAME (TEAMID)" for the
#                     final re-sign (defaults to ad-hoc "-").
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="FilmTether"
BUNDLE="${1:-Film Tether.app}"
IDENTITY="${DEVELOPER_ID:--}"
ARM_TAG="arm64_sonoma"   # macOS 14, Apple Silicon
X86_TAG="sonoma"         # macOS 14, Intel
ARM_STAGE=".compat-libs/$ARM_TAG"
X86_STAGE=".compat-libs/$X86_TAG"
X86_APP=".build/_uni/x86.app"
ARM_APP=".build/_uni/arm.app"

# Headless signing keychain (CI-style): a dedicated keychain whose password we
# control, so codesign never needs the GUI login keychain / interactive unlock.
# Set SIGN_KEYCHAIN + SIGN_KEYCHAIN_PW to use it (it must already hold the
# Developer ID identity and be on the search list).
if [[ -n "${SIGN_KEYCHAIN:-}" && -n "${SIGN_KEYCHAIN_PW:-}" ]]; then
    security unlock-keychain -p "$SIGN_KEYCHAIN_PW" "$SIGN_KEYCHAIN"
    security set-keychain-settings "$SIGN_KEYCHAIN"   # no auto-lock during the build
fi

echo "==> 1/5  Fetch both-arch Sonoma bottles"
bash scripts/fetch-compat-libs.sh "$X86_TAG" "$X86_STAGE"
bash scripts/fetch-compat-libs.sh "$ARM_TAG" "$ARM_STAGE"

# The arm64 libgphoto2 dylibs from the bottle. We feed these to the arm64 link as
# DIRECT inputs (not -L search): pkg-config emits `-L/usr/local/lib -lgphoto2`,
# whose x86_64 libgphoto2 the linker finds first and skips as wrong-arch without
# continuing the search, so a direct dylib input is the reliable way to supply
# the arm64 symbols. bundle.sh later rewrites their @@HOMEBREW@@ install names to
# @rpath, matching the x86 slice.
ARM_LIBDIR="$(dirname "$(find "$ARM_STAGE/libgphoto2" -name 'libgphoto2.6.dylib' | head -1)")"
ARM_GP="$ARM_LIBDIR/libgphoto2.6.dylib"
ARM_PORT="$ARM_LIBDIR/libgphoto2_port.12.dylib"

echo "==> 2/5  Build x86_64 slice + bundle (Sonoma dylibs)"
swift build -c release --arch x86_64
rm -rf "$X86_APP"; mkdir -p "$(dirname "$X86_APP")"
COMPAT_STAGE="$X86_STAGE" bash scripts/bundle.sh "$X86_APP" "$APP_NAME" \
  ".build/x86_64-apple-macosx/release/$APP_NAME" >/dev/null
echo "    x86 bundle: $(lipo -archs "$X86_APP/Contents/MacOS/$APP_NAME")"

echo "==> 3/5  Build arm64 slice (against arm64 bottle) + bundle"
# The arm64 link sees /usr/local's x86_64 libgphoto2 too; the linker skips the
# wrong-arch file with a warning and resolves against the arm64 bottle via -L.
swift build -c release --arch arm64 -Xlinker "$ARM_GP" -Xlinker "$ARM_PORT"
rm -rf "$ARM_APP"
COMPAT_STAGE="$ARM_STAGE" bash scripts/bundle.sh "$ARM_APP" "$APP_NAME" \
  ".build/arm64-apple-macosx/release/$APP_NAME" >/dev/null
echo "    arm bundle: $(lipo -archs "$ARM_APP/Contents/MacOS/$APP_NAME")"

echo "==> 4/5  lipo-merge the two bundles into $BUNDLE"
rm -rf "$BUNDLE"
cp -R "$ARM_APP" "$BUNDLE"
# For every Mach-O in the bundle, fuse the x86 + arm slices. Both bundles share
# an identical layout and already carry @rpath install names, so the fat file's
# load commands are consistent across arches.
while IFS= read -r armf; do
    rel="${armf#"$BUNDLE/"}"
    x86f="$X86_APP/$rel"
    [[ -f "$x86f" ]] || { echo "    ! missing x86 counterpart for $rel"; continue; }
    lipo -create "$armf" "$x86f" -output "$armf"
done < <(find "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Frameworks" \
              "$BUNDLE/Contents/Resources/camlibs" "$BUNDLE/Contents/Resources/iolibs" \
              -type f \( -name '*.dylib' -o -name '*.so' -o -name "$APP_NAME" \) 2>/dev/null)

echo "==> 5/5  Re-sign universal bundle ($IDENTITY)"
# lipo invalidated the per-arch signatures, re-sign every embedded binary, then
# the bundle (hardened runtime on the main exec for notarization-readiness).
find "$BUNDLE/Contents/Frameworks" "$BUNDLE/Contents/Resources/camlibs" \
     "$BUNDLE/Contents/Resources/iolibs" -type f \( -name '*.dylib' -o -name '*.so' \) 2>/dev/null \
  | while read -r f; do codesign --force --timestamp --sign "$IDENTITY" "$f" 2>/dev/null || \
                        codesign --force --sign "$IDENTITY" "$f"; done
RUNTIME_OPT=""; [[ "$IDENTITY" != "-" ]] && RUNTIME_OPT="--options runtime --timestamp"
codesign --force $RUNTIME_OPT --entitlements "Resources/$APP_NAME.entitlements" \
         --sign "$IDENTITY" "$BUNDLE"

# Notarize + staple so Gatekeeper clears it on any Mac with no quarantine prompt.
# Gated on NOTARY_PROFILE (a notarytool keychain profile in the signing keychain).
if [[ -n "${NOTARY_PROFILE:-}" && "$IDENTITY" != "-" ]]; then
    echo "==> 6/6  Notarize + staple (submitting to Apple, usually ~1-3 min)"
    NZIP=".build/_uni/notarize.zip"
    ditto -c -k --keepParent "$BUNDLE" "$NZIP"
    xcrun notarytool submit "$NZIP" --keychain-profile "$NOTARY_PROFILE" \
        ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} --wait
    xcrun stapler staple "$BUNDLE"
    rm -f "$NZIP"
fi

echo ""
echo "OK  →  $BUNDLE"
echo "    binary:     $(lipo -archs "$BUNDLE/Contents/MacOS/$APP_NAME")"
echo "    libgphoto2: $(lipo -archs "$BUNDLE/Contents/Frameworks/libgphoto2.6.dylib")"
echo "    codesign:   $(codesign --verify --strict "$BUNDLE" 2>&1 && echo valid || echo FAILED)"
echo "    notarized:  $(xcrun stapler validate "$BUNDLE" >/dev/null 2>&1 && echo 'stapled ✓' || echo 'no ticket')"
echo "    gatekeeper: $(spctl -a -t exec -vv "$BUNDLE" 2>&1 | awk -F'=' '/source/{print $2; exit}')"
echo "    min macOS:  $(otool -l "$BUNDLE/Contents/MacOS/$APP_NAME" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
