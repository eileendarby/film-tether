#!/usr/bin/env bash
# Film Tether: one-shot build + bundle + launch.
#
# Workflow:
#   Intel Mac: `ARCH=x86_64 bash scripts/build-and-run.sh`
#   ARM (his daily): `bash scripts/build-and-run.sh` (run locally)
#
# What it does:
#   1. Sanity-check the environment (brew, libgphoto2, Xcode CLT)
#   2. git pull (so the local tree has the latest commits)
#   3. Quit any running Film Tether
#   4. Build via SwiftPM (release config, configurable ARCH)
#   5. Bundle into "Film Tether.app" with libgphoto2 vendored
#   6. Launch the .app
#
# Env vars:
#   ARCH         arm64 (default) or x86_64
#   DEVELOPER_ID optional codesign identity (default: ad-hoc "-")
#   NO_PULL=1    skip `git pull`
#   NO_LAUNCH=1  build + bundle only, don't open
#   WITH_DEBUG=1 also build the FilmTetherDebug headless CLI binary AND launch
#                the GUI with EOS_DEBUG=1 (verbose libgphoto2 + camera state
#                logging). Default OFF, production build is just the GUI,
#                no headless CLI, no verbose logs in the user's console.

set -euo pipefail

ARCH="${ARCH:-arm64}"
APP_NAME="FilmTether"
DISPLAY_NAME="Film Tether"
BUNDLE="${DISPLAY_NAME}.app"

# Find the repo root regardless of where the script is invoked from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

echo "==> Film Tether build-and-run"
echo "    repo:   $REPO_ROOT"
echo "    arch:   $ARCH"
echo "    bundle: $BUNDLE"

# --- Pre-flight ---

if ! command -v brew >/dev/null 2>&1; then
    echo "FATAL: Homebrew not found. Install from https://brew.sh first."
    exit 1
fi

if ! brew list libgphoto2 >/dev/null 2>&1; then
    echo "==> libgphoto2 not installed via brew, installing it now (this is one-time)"
    brew install libgphoto2 pkg-config
fi

if ! command -v swift >/dev/null 2>&1; then
    echo "FATAL: swift compiler not found. Install Xcode Command Line Tools:"
    echo "       xcode-select --install"
    exit 1
fi

# Make sure the brew prefix's pkg-config is on PATH so SwiftPM finds libgphoto2.
BREW_PREFIX="$(brew --prefix)"
export PATH="$BREW_PREFIX/bin:$PATH"
export PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# --- Git pull ---

if [[ "${NO_PULL:-0}" != "1" ]] && [[ -d .git ]]; then
    echo "==> git pull"
    git pull --ff-only || echo "    (pull failed, continuing with local tree)"
fi

# --- Stop a running instance ---

pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.3

# --- Build ---

# Production build: only the GUI product. Skips the FilmTetherDebug headless
# CLI binary so .build/ stays lean and no dev surface ships with the .app.
# WITH_DEBUG=1 opts back in (also builds FilmTetherDebug + launches verbose).
if [[ "${WITH_DEBUG:-0}" == "1" ]]; then
    echo "==> swift build (arch=$ARCH, config=release, WITH_DEBUG=1, builds GUI + FilmTetherDebug CLI)"
    swift build --arch "$ARCH" -c release
else
    echo "==> swift build (arch=$ARCH, config=release, product=FilmTether, GUI only)"
    swift build --arch "$ARCH" -c release --product FilmTether
fi

BUILD_DIR=".build/${ARCH}-apple-macosx/release"
BINARY="${BUILD_DIR}/${APP_NAME}"

if [[ ! -x "$BINARY" ]]; then
    echo "FATAL: build succeeded but binary missing at $BINARY"
    exit 1
fi

# --- Bundle ---

echo "==> bundling into $BUNDLE"
rm -rf "$BUNDLE"
bash scripts/bundle.sh "$BUNDLE" "$APP_NAME" "$BINARY"

# --- Launch ---

if [[ "${NO_LAUNCH:-0}" == "1" ]]; then
    echo "==> NO_LAUNCH=1, skipping open. Bundle ready at: $BUNDLE"
    exit 0
fi

echo "==> open '$BUNDLE'"
if [[ "${WITH_DEBUG:-0}" == "1" ]]; then
    echo "    WITH_DEBUG=1, launching with EOS_DEBUG=1 (verbose camera + libgphoto2 logs)"
    EOS_DEBUG=1 open --env EOS_DEBUG=1 "$BUNDLE"
    echo "    Stream the logs from another terminal with:"
    echo "    log stream --predicate 'subsystem == \"co.wonders.filmtether\"' --info --debug"
else
    open "$BUNDLE"
fi

# Brief pause then confirm it's running.
sleep 1
if pgrep -lf "$BUNDLE" >/dev/null; then
    echo "==> running."
    pgrep -lf "$BUNDLE" | head -3
else
    echo "WARN: launched but no process found. Check Console.app for crash logs."
fi
