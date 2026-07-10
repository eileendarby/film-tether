# Changes

A dated log of code changes made to Film Tether. Newest first.

## 2026-07-09 — Restore "RAW + L" / "cRAW + L" to the Format menu (libgphoto2 patch)

**Problem:** On the R5, the Format menu offered every quality combo except
`RAW + L` and `cRAW + L`. The app shows exactly what libgphoto2's
`imageformat` widget reports, so the entries were missing at the driver
level, not in the app.

**Root cause (found against the live camera):** the R5 reports 14 supported
values for the EOS ImageFormat PTP property. libgphoto2's
`ptp_unpack_EOS_ImageFormat` condenses each value's 1–2 records
(type/size/compression) into a u16, and marks "no second record" by checking
`size == 0 && compression == 0`. On bodies using the user/custom JPEG
compression scheme (the R5 among them), large JPEG "L" is *exactly* size 0 +
compression 0 — so real `RAW + L` / `cRAW + L` entries collapsed into plain
`RAW`/`cRAW` duplicates and vanished from the choice list. The same bug made
the current value read back as "RAW" whenever the body was set to RAW+L
(setting the combo already worked; only the decode was lossy). Bug confirmed
present in libgphoto2 2.5.34 and on master as of this date.

**Fix:** one-line patch to `ptp_unpack_EOS_ImageFormat` — decide "second
record absent" from the record count the camera itself reports instead of
sniffing zero values. Verified on the R5: all 14 choices decode (including
both `+ L` combos) and each round-trips through set + readback. Worth
submitting upstream to gphoto/libgphoto2.

**Changes:**

- `patches/eos-imageformat-L-combos.diff` — the libgphoto2 patch, with a
  full explanation in its header.
- `scripts/build-patched-camlib.sh` — downloads the libgphoto2 source
  matching the installed brew version, applies the patch, builds just the
  ptp2 camlib, relinks it against brew's dylibs, and installs it at
  `vendor/camlibs/<version>/ptp2.so` (gitignored build artifact).
- `Makefile` — new `make patched-camlib` target; `make debug`/`debug-test`
  route the headless CLI through the patched camlib when present (via the
  `CAMLIBS` env var libgphoto2 honors).
- `scripts/bundle.sh` — prefers `vendor/camlibs/<version>/ptp2.so` over the
  stock brew camlib when the versions match. Native builds only;
  compat/universal builds keep the stock bottle camlibs (different OS/arch).
  A brew upgrade to a new libgphoto2 version silently falls back to stock
  (menu loses the two combos again) until the script is re-run.
- `.gitignore` — added `vendor/` and `.camlib-build/`.
- `README.md` — documented `make patched-camlib`.

## 2026-07-09 — Always save extensions uppercase

Saved filenames now always get an UPPERCASE extension (`.CR3`, `.JPG`),
regardless of the case the camera's filename or the user's pattern used.

- `Sources/Camera/CameraCapture.swift` — `resolveFilename` uppercases
  `cameraExtension` on entry, and the save-time extension correction now
  compares exactly (not case-insensitively) so a lowercase literal like
  `.cr3` in a pattern is also normalized.
- `Tests/CameraTests/FilenameTemplateTests.swift` — two new tests
  (lowercase camera extension, lowercase literal pattern extension).

## 2026-07-09 — Debug CLI: `choices` command + stderr libgphoto2 logging

Diagnostics added while chasing the Format-menu bug:

- `Sources/Debug/DebugCLI.swift` — new `choices NAME` subcommand dumps a
  RADIO/MENU widget's full choice list plus current value (the app's pickers
  show exactly these strings). With `EOS_DEBUG=1` the CLI now pipes
  libgphoto2's internal logging to stderr (the GUI app bridges to unified
  logging instead; a headless CLI wants greppable stderr).

**Note:** Homebrew's libgphoto2 is built with `--disable-debug`, which
compiles libgphoto2's internal logging out entirely — so `EOS_DEBUG=1` shows
libgphoto2 messages only from the port/core layers, not the ptp2 camlib, and
the same applies to the GUI's `make run-debug` bridge. Diagnosing the decode
bug required a local from-source build with logging enabled.

## 2026-07-08 — Save captures under the camera's true file type (Canon R5 CR3 fix)

**Problem:** On a Canon R5, captured files arrived named `.CR2` but Finder
reported them as 8-bit RGB / sRGB, while EOS Utility 3 delivered a proper
`.CR3` (16-bit / Display P3 when decoded). The app never converted anything —
it downloads the camera's bytes untouched — but two bugs mislabeled and
dropped files:

1. The filename pattern hardcoded a `.CR2` extension
   (`IMG_{ymd}_{hms}_{seq}.CR2`), so an R5's CR3 or JPEG bytes were saved
   under a lying `.CR2` name and macOS misidentified them.
2. With the body set to RAW+JPEG, `gp_camera_capture` returns only the first
   file the camera created (often the JPEG); the companion RAW was never
   downloaded. That first file — a real JPEG (8-bit, sRGB) — is what was
   landing on disk with a `.CR2` name.

**Changes:**

- `Sources/Camera/CameraCapture.swift`
  - The saved extension now always comes from the camera's own filename
    (`.CR2` on a 7D, `.CR3` on an R5, `.JPG` for JPEG quality). A new `{ext}`
    filename-pattern token resolves to it, and any literal extension in a
    pattern is corrected to the real one at save time (never trusts the
    pattern over the bytes).
  - After the primary download, the libgphoto2 event queue is drained for
    queued `FILE_ADDED` events (up to 2 s, stops after 400 ms of silence) so
    RAW+JPEG captures save **both** files with the same base name, matching
    EOS Utility. Each on-camera copy is still deleted after download.
  - `CaptureResult` gained `allPaths` (every saved file); `path` is now the
    RAW when a pair was captured.
  - Download logic factored into a `downloadFile` helper; the on-camera
    filename is now logged.
  - `sanitizeFilename` empty-name fallback changed `IMG.CR2` → `IMG` (the
    true extension is appended afterward).
- `Sources/App/AppSettings.swift` — default pattern is now
  `IMG_{ymd}_{hms}_{seq}.{ext}`; one-time migration moves installs that had
  stored the old `.CR2` default to the new one (custom patterns untouched).
- `Sources/App/AppModel.swift` — `capturedFiles` records every file of a
  capture, not just the first.
- `Sources/App/SettingsView.swift` — capture-folder and filename-pattern help
  text updated for `{ext}` and RAW+JPEG behavior.
- `Sources/App/FilmTetherApp.swift` — menu help text no longer says "CR2".
- `Sources/Debug/DebugCLI.swift` — debug capture pattern uses `{ext}`; usage
  text updated.
- `Tests/CameraTests/FilenameTemplateTests.swift` — added tests for `{ext}`
  substitution, literal-extension correction, matching-extension passthrough,
  missing-extension append, and the nil-extension (Settings preview) path.
- `README.md` — RAW-capture bullet updated.

**Note on color:** the "16-bit RGB, Display P3" that EOS Utility's files show
is just how macOS reports a decoded CR3's raw sensor data. Film Tether saves
the identical bytes, so once the extension is truthful the metadata matches.

## 2026-07-08 — Repair the unit-test suite (pre-existing breakage)

`swift test` failed to compile on the current Swift toolchain, independent of
the capture fix above (33 errors on the pristine tree): tests call pure
`static` helpers on `@CameraActor` classes synchronously, which newer Swift
concurrency checking rejects. Fixed by marking those pure helpers
`nonisolated` (the project's existing convention, e.g.
`CameraCapture.resolveFilename`):

- `Sources/Camera/CameraSession.swift` — `parseFirmware(from:)`,
  `isFirmwareTooOld(_:)`, `knownBuggyFirmwares`.
- `Sources/Camera/LiveView.swift` — `parseJPEGDimensions(_:)`.
- `Sources/Camera/LiveZoom.swift` — `meanCenterPixelDifference(baseline:zoomed:)`,
  `decodeCenterLuminance(_:size:)`.
- `Tests/CameraTests/ZoomProbeMathTests.swift` —
  `testJPEGCropDownsizesCenter` asserted the cropped JPEG had fewer *bytes*
  than the source, which fails on modern ImageIO (fixed header/profile
  overhead of a 40×40 re-encode exceeds a 983-byte solid-gray source). It now
  decodes the crop and asserts the 40×40 dimensions directly.

Result: all 34 tests pass.

