.PHONY: build bundle run run-debug clean tests check format help doctor dist dist-compat dist-universal debug debug-test

APP_NAME       := FilmTether
# Display-friendly bundle filename — macOS supports spaces in .app paths,
# Finder/menubar/Dock prefer it (matches CFBundleName + CFBundleDisplayName).
DISPLAY_NAME   := Film Tether
BUNDLE         := $(DISPLAY_NAME).app
ARCH           := arm64
CONFIG         := release
BUILD_DIR      := .build/$(ARCH)-apple-macosx/$(CONFIG)
BINARY         := $(BUILD_DIR)/$(APP_NAME)
DEBUG_BIN      := $(BUILD_DIR)/FilmTetherDebug

# Brew env — exported so `swift build` and `pkg-config` find libgphoto2 on Apple Silicon
# even when run from contexts that don't source ~/.zshrc (Make, GUI launchers, agents).
BREW_PREFIX   := $(shell brew --prefix 2>/dev/null || echo /opt/homebrew)
export PKG_CONFIG_PATH := $(BREW_PREFIX)/lib/pkgconfig:$(PKG_CONFIG_PATH)
export PATH := $(BREW_PREFIX)/bin:$(PATH)

help:
	@echo "Film Tether build"
	@echo ""
	@echo "  make build    Compile via SwiftPM (release, arm64)"
	@echo "  make tests    Run the unit-test target"
	@echo "  make bundle   Build + assemble $(BUNDLE) with libgphoto2 vendored"
	@echo "  make run      Build + bundle + open the .app"
	@echo "  make run-debug  Same as run + EOS_DEBUG=1 (verbose camera+libgphoto2 logs)"
	@echo "  make dist     Build + bundle + zip for friend-handoff (no brew needed on their Mac)"
	@echo "  make debug-test  Run the headless autonomous test suite against the 7D"
	@echo "  make debug CMD=\"…\"  Run a single CLI subcommand (snapshot, capture, meter, …)"
	@echo "  make clean    Remove .build/ and $(BUNDLE)"
	@echo "  make check    Static checks (swift package describe + plist lint)"
	@echo ""
	@echo ""
	@echo "Env:"
	@echo "  DEVELOPER_ID  Optional Developer ID Application string for codesign"
	@echo ""

build:
	@swift build -c $(CONFIG) --arch $(ARCH)

tests:
	@swift test --arch $(ARCH)

# Run the autonomous headless test suite against a real 7D. Assumes the GUI
# app is NOT running (the USB can only be claimed by one process at a time).
# Output is PASS/FAIL per check with evidence — exactly what to skim post-cycle.
debug-test: build
	@if pgrep -x $(APP_NAME) >/dev/null 2>&1; then \
		echo "Film Tether GUI is running — quit it first (USB is single-claim)"; \
		exit 1; \
	fi
	@$(DEBUG_BIN) test

# Run a single CLI subcommand without launching the GUI. Examples:
#   make debug CMD="snapshot"
#   make debug CMD="capture ~/Pictures/Film Tether"
#   make debug CMD="meter 10"
#   make debug CMD="sync-clock"
debug: build
	@if pgrep -x $(APP_NAME) >/dev/null 2>&1; then \
		echo "Film Tether GUI is running — quit it first (USB is single-claim)"; \
		exit 1; \
	fi
	@$(DEBUG_BIN) $(CMD)

bundle: build
	@bash scripts/bundle.sh "$(BUNDLE)" "$(APP_NAME)" "$(BINARY)"

run: bundle
	@open "$(BUNDLE)"

# Launch with EOS_DEBUG=1 — every Camera state change, every libgphoto2 internal
# log message lands in unified logging. Stream it from another terminal with:
#   log stream --predicate 'subsystem == "co.wonders.filmtether"' --info --debug
run-debug: bundle
	@pkill -x $(APP_NAME) 2>/dev/null || true
	@sleep 0.5
	@EOS_DEBUG=1 open --env EOS_DEBUG=1 "$(BUNDLE)"
	@echo ""
	@echo "Stream the app's logs (run in another terminal):"
	@echo "  log stream --predicate 'subsystem == \"co.wonders.filmtether\"' --info --debug"

clean:
	@rm -rf .build "$(BUNDLE)"

check:
	@swift package describe > /dev/null
	@plutil -lint Resources/Info.plist
	@plutil -lint Resources/$(APP_NAME).entitlements
	@echo "OK"

format:
	@swift-format -i -r Sources Tests || echo "(swift-format not installed — skipping)"

dist: bundle
	@echo ">> Zipping $(BUNDLE) for distribution..."
	@rm -f "$(APP_NAME).zip"
	@ditto -c -k --keepParent "$(BUNDLE)" "$(APP_NAME).zip"
	@SIZE=$$(du -h "$(APP_NAME).zip" | cut -f1); \
	echo ""; echo "OK  →  $(APP_NAME).zip ($$SIZE)"; \
	echo ""; echo "  Hand-off to a friend (no brew needed; must be on your macOS or newer):"; \
	echo "    1. Send $(APP_NAME).zip via AirDrop / Syncthing / cloud"; \
	echo "    2. They unzip, then clear the quarantine flag once:"; \
	echo "         xattr -dr com.apple.quarantine \"/path/to/$(BUNDLE)\""; \
	echo "       (right-click → Open sometimes works, but xattr is reliable)"; \
	echo "    3. Plug in a Canon EOS DSLR with PTP enabled and shoot"

# Build a friend bundle that runs on an OLDER macOS than this host. Pulls the
# Homebrew bottles for an older OS tag (default macOS 14 / Sonoma on Apple
# Silicon), vendors those instead of your native ones, and zips separately.
# Same packages as your normal build — just compiled for the older OS.
#   make dist-compat                    # arm64_sonoma (macOS 14)
#   make dist-compat TAG=arm64_sequoia  # macOS 15
TAG ?= arm64_sonoma
dist-compat:
	@bash scripts/fetch-compat-libs.sh "$(TAG)" ".compat-libs/$(TAG)"
	@swift build -c $(CONFIG) --arch $(ARCH)
	@COMPAT_STAGE=".compat-libs/$(TAG)" bash scripts/bundle.sh "$(BUNDLE)" "$(APP_NAME)" "$(BINARY)"
	@rm -f "$(APP_NAME)-$(TAG).zip"
	@ditto -c -k --keepParent "$(BUNDLE)" "$(APP_NAME)-$(TAG).zip"
	@SIZE=$$(du -h "$(APP_NAME)-$(TAG).zip" | cut -f1); \
	echo ""; echo "OK  →  $(APP_NAME)-$(TAG).zip ($$SIZE) — runs on $(TAG) and newer"; \
	echo "       Send this one to the friend on the older macOS; clear quarantine as above."

# Build ONE universal (arm64 + x86_64) bundle targeting macOS Sonoma (14)+,
# entirely on this host — fetches both-arch Homebrew bottles, builds each slice,
# lipo-merges. This is the publish/distribution artifact (GitHub) AND what runs
# native on Apple Silicon. Set DEVELOPER_ID=... to sign for real.
#   make dist-universal
#   make dist-universal DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
dist-universal:
	@DEVELOPER_ID="$(DEVELOPER_ID)" bash scripts/build-universal.sh "$(BUNDLE)"
	@rm -f "$(APP_NAME)-universal.zip"
	@ditto -c -k --keepParent "$(BUNDLE)" "$(APP_NAME)-universal.zip"
	@SIZE=$$(du -h "$(APP_NAME)-universal.zip" | cut -f1); \
	echo ""; echo "OK  →  $(APP_NAME)-universal.zip ($$SIZE) — universal, macOS 14+"



doctor:
	@echo "=== brew prefix ==="
	@brew --prefix
	@echo
	@echo "=== brew --prefix libgphoto2 ==="
	@brew --prefix libgphoto2 2>/dev/null || echo "NOT INSTALLED — run: brew install libgphoto2 pkg-config"
	@echo
	@echo "=== pkg-config --cflags libgphoto2 ==="
	@pkg-config --cflags libgphoto2 || echo "pkg-config can't find libgphoto2 — check PKG_CONFIG_PATH"
	@echo
	@echo "=== pkg-config --libs libgphoto2 ==="
	@pkg-config --libs libgphoto2
	@echo
	@echo "=== swift toolchain ==="
	@swift --version | head -2
	@echo
	@echo "=== xcode-select ==="
	@xcode-select -p
	@echo
	@echo "=== libgphoto2 camlibs ==="
	@ls "$$(brew --prefix libgphoto2)/lib/libgphoto2/" 2>/dev/null || echo "(none found)"
	@echo
	@echo "=== ptpcamerad status ==="
	@launchctl print system/com.apple.imagecapture.ptpcamerad 2>&1 | head -3 | grep -E "state =|state-status" || echo "(service not registered — already disabled or not present)"
	@echo
	@echo "=== Architecture note ==="
	@echo "    Transport: libgphoto2 over USB (CGPhoto2 systemLibrary)."
	@echo "    Without that step, libgphoto2 hits -53 IO_USB_CLAIM in the race with launchd."
