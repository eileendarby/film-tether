# Changes

A dated log of code changes made to Film Tether. Newest first.

## 2026-07-28 — Negative inversion, black-and-white preview, click-to-set white balance

Roadmap items 5 and 8 plus preview inversion, built together because they're
the same thing mechanically: host-side processing of the live frame. All are
display corrections — the camera is never reconfigured and captured files are
never re-encoded — and all are recorded so the treatment can be replayed onto
the RAW later and reported to the server.

- **Invert** (Cmd-I, or the Negative/Positive toolbar button). Shows a negative
  as the positive image it will become. Judging framing, focus and exposure on
  an inverted image is guesswork.
- **B&W preview** (Cmd-B, or the Color/B&W toolbar button). Raw pixels off a
  black-and-white negative carry no meaningful colour, so showing them in
  colour is just noise to judge exposure and focus through.
- **Click-to-set white balance.** Arm the eyedropper, click the unexposed film
  base, and its cast is neutralised. Gains are per-channel rather than a colour
  temperature, because a film base is off-neutral on *both* axes and the
  camera's Kelvin-only control can slide blue↔amber but cannot touch
  green↔magenta at all. That's precisely why the correction lives on the host.

**Stage order is deliberate:** white balance → invert → monochrome → peaking.
White balance comes before inversion because the film base cast is a property
of the *negative*, so it's neutralised there and the result is then inverted —
that's the order film scanning wants. Invert and monochrome commute
(desaturation is linear, so `luma(1−c) == 1−luma(c)`). Peaking is last so its
highlights sit on top and keep their colour over a desaturated or inverted
frame. Verified on a real R5 frame: after white balance the sampled point sits
at level 0.368, and after inversion at 0.632 — exactly `1 − 0.368` — still
neutral to within JPEG rounding.

**One pass, not four.** Peaking used to decode the JPEG, filter it, re-encode
to JPEG, and hand that back to be decoded again. Adding three more effects that
way would have meant four decodes and three pointless lossy round-trips per
frame, at 30 fps. `PreviewPipeline` now decodes once, runs every enabled stage
as a single Core Image graph, and produces one bitmap.
`FocusPeaking` was refactored from JPEG-to-JPEG into a `CIImage` stage to suit.
When nothing is enabled the pipeline returns nil and the caller uses the raw
JPEG, so the common case still costs nothing.

**The load-bearing detail: colour management is deliberately disabled** in the
pipeline's `CIContext` (`workingColorSpace` of null). `PixelSampler` reads
gamma-encoded sRGB bytes to compute the gains, so Core Image has to apply them
in that same space. Measured on a synthetic film-base colour, applying gains
through a default (managed) context leaves a channel spread of **0.384** — the
correction barely lands, because a gain of k applied in linear space behaves
like k^(1/2.2). Through the unmanaged context the spread is **0.0000**. Verified
again on a real R5 preview frame: a warm cast of R 0.543 / G 0.372 / B 0.190
corrected to a spread of 0.0013, which is JPEG rounding.

A related trap found while testing: `CGColorSpaceCreateDeviceRGB()` is **not**
sRGB on macOS. Reading through it turned a pure sRGB red into
(0.98, 0.15, 0.20), which would have baked a phantom cast into every sample.
`PixelSampler` now names sRGB explicitly.

**Changes:**

The eyedropper samples the **unadjusted** frame, so a second click on the same
spot is a no-op rather than compounding the correction.

**White-balance picking is disabled while the preview is inverted.** It would
work — the eyedropper reads the original frame either way — but with a positive
on screen the film base is the *darkest* part of the picture rather than the
brightest, so the operator is being asked to click the opposite of what they've
learned to look for. That's a deliberate guard against picking the wrong spot,
not a technical limitation. Turning invert on while the eyedropper is armed also
disarms it: otherwise the button would grey out while the pane still sampled on
the next click.

- `Sources/Scan/PreviewAdjustments.swift` — new. `ChannelGains` (neutralising
  math, clamped so a near-black sample can't produce an enormous multiplier,
  refused outright below a usable level) and `PreviewAdjustments`.
- `Sources/Scan/PixelSampler.swift` — new. Averages a 9×9 patch rather than
  reading one pixel, which is what makes repeated clicks on the same film base
  agree instead of chasing grain.
- `Tests/ScanTests/PreviewAdjustmentsTests.swift`, `PixelSamplerTests.swift` —
  17 tests, including that the gains actually neutralise the colour they came
  from, that brightness is preserved so correcting isn't also an exposure
  change, and quadrant tests pinning the y-down/top-left sampling convention.
- `Sources/App/PreviewPipeline.swift` — new. The single pass, plus the
  eyedropper's sampling entry point.
- `Sources/App/FocusPeaking.swift` — `apply(toJPEG:)` became `overlay(on:)`.
- `Sources/App/AppModel.swift` — adjustment state, eyedropper arming, sampling
  against the **unadjusted** frame (sampling the corrected preview would
  compound, so a second click would drift instead of being a no-op), and a
  short-lived footer notice so a refused sample doesn't look like a dead click.
- `Sources/App/AppSettings.swift` — both persisted; they're properties of the
  film being scanned, not of the app session.
- `Sources/App/LiveViewPane.swift` — while armed, the eyedropper takes the whole
  pane so it can't fight the metering box over the same click; the point is
  un-rotated before sampling. The pointer becomes a crosshair so the pixel about
  to be sampled is unambiguous. `NSCursor.push()` is a stack, so the layer
  guards both directions with a flag and pops on `onDisappear` — taking a sample
  disarms the picker, which tears the layer down while the pointer is still
  inside it, so no hover-exit ever arrives and an unguarded push would leak the
  crosshair to the whole app.
- `Sources/App/ExposureBar.swift`, `FilmTetherApp.swift`, `StatusFooter.swift` —
  buttons, menu items (including Reset White Balance), and footer readouts.
- `Sources/App/ExposureBar.swift` — the live-view button now reads as current
  state ("Live View ON") rather than as the action it performs ("Stop Live
  View"). Every other toggle in the bar already showed state, so this was the
  odd one out; an audit confirmed the rest were consistent. Menu items keep
  command phrasing, which is the macOS convention for menus.
- `Sources/App/ExposureBar.swift`, `MainView.swift`, `FilmTetherApp.swift` —
  responsive toolbar. Below 1400pt of bar width the secondary toggles (invert,
  B&W, white balance, peaking, box) collapse to icons alone; capture, live view,
  zoom and rotation keep their text at every size. The last two have to: they
  double as readouts and their value — the angle, the fit percentage — can't be
  shown by an icon. Collapsing the rest costs nothing readability-wise because
  each icon already encodes its own on/off state, and each button has a `.help`
  tooltip naming it.

  **No pixel thresholds anywhere in this.** A first attempt used a hand-guessed
  1400pt threshold with a 1150pt window minimum, and both numbers were wrong in
  the direction that hurts: the labelled bar actually needs more than 1400, so
  labels stayed on while being clipped across a wide band of window sizes, and
  1150 was ~130pt below what the bar needs even in its compact form, so the
  window could be dragged narrow enough to lose controls entirely.

  The fix removes the guessing rather than re-tuning it:

  - `ViewThatFits(in: .horizontal)` picks the labelled bar when it fits and the
    icons-only bar otherwise, so the switch lands exactly where clipping would
    have started. This must not sit inside a horizontal `ScrollView` — a scroll
    view offers unlimited width, so the labelled variant would always "fit" and
    the compact one would never be chosen.
  - The `ScrollView` is gone, which is also what stops buttons being scrolled
    out of sight.
  - The window's explicit `minWidth` is gone too. With no scroll view absorbing
    it, the compact bar's own intrinsic width propagates up as the content
    minimum, and `.windowResizability(.contentMinSize)` makes that the window
    minimum. **Measured at 1280×852** — so the window physically cannot be made
    narrow enough to hide a control, and the figure stays correct on its own as
    buttons are added later instead of silently rotting.
  - `AppDelegate` gained an `EOS_DEBUG=1` report of the window's enforced
    minimum (unified logging plus a temp file, since a GUI app has no useful
    stderr). That measurement is what confirmed the 1280 above, and it makes a
    future regression visible rather than silent.

  Zoom also moved to sit beside the live-view button, which puts all four
  always-labelled controls together in one group.
- `README.md` — documented both.

## 2026-07-28 — Verified "Sync Camera Clock to Host" on the Canon R5

No behaviour change — this entry records a hardware verification, because the
clock-sync code was written entirely against the 7D and had never been tested
on the R5.

**Result: it works unmodified.** A clock deliberately skewed by an hour was
corrected to within a second, and EXIF `DateTimeOriginal` on the resulting CR3
matched host wall clock (`-07:00`, Los Angeles, DST on). The 7D-era
`cameraTZOffsetMinutes` workaround is *not* needed on this body; leave it at 0.

**What the R5 actually exposes**, versus the 7D's single `datetimeutc`:

| leaf | type | R5 behaviour |
| --- | --- | --- |
| `settings/datetime` | DATE | camera **local** clock; reads fine, **writes silently ignored** |
| `settings/datetimeutc` | DATE | camera **UTC** clock; reads and writes both work |
| `actions/syncdatetime` | TOGGLE | present |
| `actions/syncdatetimeutc` | TOGGLE | present |

Two things worth carrying forward:

- `settings/datetime` advertises `Readonly: 0` and accepts a write with no
  error, then leaves the value untouched. `syncDateTimeToHostLocal` writes
  `datetimeutc`, which is the one that takes — so this is a trap for a future
  "simplification", not a live bug. Noted in the function's doc comment.
- The read path in `snapshot()` reads `datetime`, and a prior worry was that it
  might come back nil on the R5 the way it does on a 7D. It doesn't: the leaf
  exists and reports correctly, so the footer clock and its drift indicator
  work on this body.

- `Sources/Camera/CameraProperties.swift` — documented the R5 findings on
  `syncDateTimeToHostLocal`. Comment only.

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

