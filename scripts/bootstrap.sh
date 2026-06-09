#!/usr/bin/env bash
# bootstrap.sh, first-time Mac setup for Film Tether.
# Run this once after cloning. For everyday iterate use `make` directly.
#
# Usage:
#   cd FilmTether
#   ./scripts/bootstrap.sh

set -euo pipefail

cd "$(dirname "$0")/.."

echo "Film Tether, Mac bootstrap"
echo "===================================="

# 1. Xcode Command Line Tools
echo ">> Checking Xcode CLT..."
if ! xcode-select -p >/dev/null 2>&1; then
    echo "   NOT INSTALLED."
    echo "   Run:  xcode-select --install"
    echo "   Then re-run this script."
    exit 1
fi
echo "   OK: $(xcode-select -p)"

# 2. Homebrew
echo ">> Checking Homebrew..."
if ! command -v brew >/dev/null 2>&1; then
    echo "   NOT INSTALLED."
    echo "   Get it from https://brew.sh and re-run."
    exit 1
fi
echo "   OK: $(brew --prefix)"

# Make sure brew's bin is on PATH for the rest of this script
export PATH="$(brew --prefix)/bin:$PATH"
export PKG_CONFIG_PATH="$(brew --prefix)/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# 3. Brewfile dependencies
echo ">> Checking Brewfile dependencies..."
if [ ! -f Brewfile ]; then
    echo "   Brewfile not found, are you in the project root?"
    exit 1
fi
if ! brew bundle check >/dev/null 2>&1; then
    echo "   Installing missing dependencies (this may take a few minutes the first time)..."
    brew bundle
else
    echo "   OK: all Brewfile dependencies satisfied"
fi

# 4. Verify pkg-config can resolve libgphoto2
echo ">> Verifying libgphoto2 via pkg-config..."
if ! pkg-config --cflags libgphoto2 >/dev/null 2>&1; then
    echo "   pkg-config can't find libgphoto2."
    echo "   Run 'make doctor' for full diagnostics."
    exit 1
fi
echo "   OK: $(pkg-config --modversion libgphoto2)"

# 5. Swift toolchain
echo ">> Checking Swift toolchain..."
if ! command -v swift >/dev/null 2>&1; then
    echo "   swift not on PATH. Did Xcode CLT install correctly?"
    exit 1
fi
echo "   OK: $(swift --version | head -1)"

# 6. Build + bundle + launch
echo
echo ">> Building (release, arm64)..."
make build
echo
echo ">> Bundling .app..."
make bundle
echo
echo ">> Launching FilmTether.app..."
make run

cat <<'EOF'

Bootstrap complete. Day-to-day workflow:

  make build      Compile only
  make tests      Run unit tests
  make run        Build + bundle + launch
  make clean      Nuke .build/ and the .app
  make doctor     Print all relevant tool versions + brew paths

EOF
