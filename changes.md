# Changes

A dated log of code changes made to Film Tether. Newest first.

## 2026-07-09 — Always save extensions uppercase

Saved filenames now always get an UPPERCASE extension (`.CR3`, `.JPG`),
regardless of the case the camera's filename or the user's pattern used.

- `Sources/Camera/CameraCapture.swift` — `resolveFilename` uppercases
  `cameraExtension` on entry, and the save-time extension correction now
  compares exactly (not case-insensitively) so a lowercase literal like
  `.cr3` in a pattern is also normalized.
- `Tests/CameraTests/FilenameTemplateTests.swift` — two new tests
  (lowercase camera extension, lowercase literal pattern extension).

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

