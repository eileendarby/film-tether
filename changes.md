# Changes

A dated log of code changes made to Film Tether. Newest first.

## 2026-07-28 — Preview zoom as percentages, with a Fit mode (and a layout fix)

**The bug first:** rotating the preview pushed the exposure toolbar and status
footer off the bottom of the window. `NSImageView` publishes the image's pixel
size as its `intrinsicContentSize`, and SwiftUI honours that — so a rotated
(tall) frame grew the `VStack` past the window height. The enclosing
`aspectRatio` already decides how big the pane should be, so `ImagePane` now
opts out of intrinsic sizing entirely (`NSView.noIntrinsicMetric` on both axes)
and clips its layer. The window is not resized; the layout simply stays inside
it, which is also what keeps the interface intact at 100% where the image is
routinely larger than the pane.

**The zoom control** was a two-state toggle labelled "Zoom 1× / Zoom 5×". It's
now a three-state cycle labelled in percentages, since percentages are what
scanning software speaks:

- **Fit (N%)** — the whole frame scaled to the pane. Default. N is computed from
  real laid-out geometry, so it updates on window resize *and* on rotation: the
  same frame turned on its side fits at a genuinely different percentage.
- **100%** — one frame pixel per point, no scaling. The honest reference view.
- **500%** — the camera's own sensor punch-in, as before. Worth stressing that
  this is real sensor detail, not an upscale of the preview JPEG, which is why
  it stays bound to `eoszoom` rather than becoming a host-side scale.

Fit and 100% are both host-side scaling of the same full-frame stream, so
switching between them costs no USB traffic at all — only entering or leaving
500% talks to the body.

**Changes:**

- `Sources/Scan/PreviewZoom.swift` — new. The three states, cycle order, labels,
  and the pure fit-percentage calculation.
- `Tests/ScanTests/PreviewZoomTests.swift` — 8 tests, including one that pins
  the "rotation recalculates the zoom" requirement as arithmetic: the same frame
  in the same pane fits at 75% landscape and 50% portrait.
- `Sources/App/LiveViewPane.swift` — the intrinsic-size fix and layer clipping;
  `.scaleNone` at 100% vs `.scaleProportionallyUpOrDown` otherwise; reports its
  laid-out size to the model so the Fit percentage can be real.
- `Sources/App/AppModel.swift` — `previewZoom`, `previewPaneSize`,
  `previewFitPercent`, `previewZoomLabel`, and the cycle/set actions. Session
  state, not persisted: Fit is the right thing to land on each time. Also fixes
  momentary Shift-hold, which used to dump you at Fit on release even if you'd
  been at 100%; it now restores the zoom you came from.
- `Sources/App/ExposureBar.swift` — the button cycles instead of toggling, fixed
  width so it doesn't twitch as the percentage changes mid-resize.
- `Sources/App/StatusFooter.swift` — readout follows the new labels.

## 2026-07-27 — Rotate the live preview in 90° increments

First item of the film-scanning feature roadmap. The preview can now be turned
a quarter turn at a time so the negative reads right-way-up on screen no matter
how the copy stand and the film holder are oriented.

Rotation is a **display transform only** — nothing is written to the camera and
captured files keep the body's native orientation. The value is persisted, both
because a scanning rig's orientation is fixed for a whole session and because
the rotation has to travel with each scan as metadata later (roadmap items 3
and 7).

**Design note — why everything else stays in sensor space:** the rotation is
applied as the very last step of frame composition, after the zoom box has been
drawn in. Metering centre, the measured `eoszoomposition` calibration, focus
peaking, and the crop geometry still to come all keep working in unrotated
sensor coordinates, so none of that hard-won calibration had to be re-measured.
Only two places know rotation exists: the final blit, and the pointer/arrow-key
mapping that converts what the user did on screen back into sensor space.

**Changes:**

- `Sources/Scan/` — **new library target** for the film-scanning domain model.
  It's free of libgphoto2 and SwiftUI on purpose: `AppModel` is `@MainActor`
  and window-server-bound, so logic living there can't be unit-tested. Crop
  geometry, film sizes, and the sidecar payload will land here too.
- `Sources/Scan/PreviewRotation.swift` — the rotation type. Quarter-turn
  cycling, the sensor↔display point mapping and its direction-only variant for
  arrow keys, aspect-ratio flipping, and an exact (non-resampling) CGImage
  rotation.
- `Tests/ScanTests/PreviewRotationTests.swift` — 12 tests. Beyond the round-trip
  and cycling properties, one test marks a single pixel and asserts where it
  lands after each turn; that's what actually pins down the sign of the rotation
  angle, since a CGBitmapContext is y-up and a *visual* clockwise turn is a
  negative angle there.
- `Package.swift` — registered the `Scan` target + `ScanTests`, and added `Scan`
  as an `App` dependency.
- `Sources/App/AppSettings.swift` — `previewRotation`, persisted. A missing key
  reads as 0, which is exactly `.none`, so no migration was needed.
- `Sources/App/AppModel.swift` — `previewRotation` / `previewAspectRatio` and
  the two rotate actions; frame composition rotates last; arrow-key nudges of
  the zoom box now map the pressed direction through the rotation, so Up still
  moves the box up on screen at every orientation.
- `Sources/App/LiveViewPane.swift` — pane letterboxes to 2:3 instead of 3:2 on a
  quarter turn, and click/drag positions un-rotate before clamping (clamping in
  the wrong space would have pinned the wrong edges).
- `Sources/App/ExposureBar.swift` — a rotate button, sitting next to the live-view
  toggle, whose label doubles as the current-rotation readout. Fixed width, sized
  for the widest label ("270°") so the number is never clipped and the
  neighbouring buttons don't shuffle as the angle changes.
- `Sources/App/FilmTetherApp.swift` — Cmd-R rotates right, Cmd-Shift-R rotates
  left.
- `README.md` — documented the feature.

**Still open on this item:** the roadmap wants rotation remembered "until the
negative size changes". Negative size arrives with auto-crop, so `AppSettings`
carries a TODO to reset rotation on a size change once that concept exists.

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

