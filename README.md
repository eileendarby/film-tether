# Film Tether

A small, native macOS app for tethering Canon EOS DSLRs over USB. It drives a Canon EOS body so you can preview and fire shots from your Mac.

I built it for my own DSLR film-scanning rig. My Canon EOS 7D only works with Canon's EOS Utility 2, and that one doesn't behave well on recent macOS. It works fine as a plain tether too. This is a personal project. It scratched my own itch and helped a friend with a 70D, and maybe a few other people will find it useful.

Open source, MIT, macOS 14+.

## What it does

The handful of things that actually matter for the way I use it.

- **Live preview.** Standard tethered live preview, straight from the camera. On my 7D it's a few frames per second. A newer body may be quicker.
- **RAW capture.** Saves the camera's RAW file (`.CR2`, `.CR3`, whatever the body produces) straight to a folder you pick, untouched and under its true extension. What the camera makes is what you get; RAW+JPEG saves both files.
- **Work through a roll.** Tap Space to fire a frame, so working through a roll of negatives is quick.
- **Exposure controls.** ISO, shutter, aperture, and white-balance Kelvin, all from the Mac. A control greys out when the current mode makes it read-only, so aperture priority just works.
- **Rotate the preview.** Turn the live view 90° at a time (Cmd-R, or Cmd-Shift-R the other way) so the negative reads right-way-up however the copy stand is set up. Display only — the camera and the saved files are never touched — and the setting is remembered.
- **Positive preview.** Cmd-I inverts the live view so a negative shows as the positive image it will become, instead of making you judge framing and focus on an inverted picture. The captured RAW is still the negative.
- **Black-and-white preview.** Cmd-B shows the preview in mono. Raw pixels off a B&W negative carry no useful colour, so it's easier to judge exposure and focus without it.
- **Click-to-set white balance.** Arm the eyedropper, click the unexposed film base, and its colour cast is neutralised. The blue/amber half is sent to the camera as a colour temperature, so it lands in the captured RAW; the green/magenta half, which a Kelvin control can't express, is corrected on the preview. Click again to refine.
- **Zoom and pan.** Fit, 100%, or 500%. At 100% the preview fills the window instead of letterboxing. Zoomed in either way, scroll or middle-drag to pan, and a thumbnail of the whole negative appears in the corner with a box marking what you're looking at — click or drag in it to jump somewhere else.
- **Auto-crop.** Finds the negative under the lens and puts an adjustable crop box on it — drag the corners or the edge handles, and the corners are shown in the status bar. It remembers the film format between negatives and uses it to check the result, so a detection of a shape no such frame could have is rejected and a crop is built from the format and the holder instead.
- **Focus check.** Hold Shift to punch in using the camera's sensor and confirm your focus is sharp.
- **Focus control.** Keyboard shortcuts for stepping focus, when the conditions are right (lens set to AF, live view on).
- **Focus peaking.** An adjustable overlay that attempts to highlight what's in focus (far from perfect).

## Honest caveats

I'd rather be upfront than oversell it.

- The focus zoom works, and you can get sharp focus with it. It just doesn't always land on the exact spot you click.
- I've only tested it on my 7D and a friend's 70D. I don't know how many other EOS bodies it works with.
- Other cameras, or other brands, might be straightforward to add, since it's built on the open-source libgphoto2 project. You would still have to work through it with the camera in hand.

It sticks to one job: tethered capture. It doesn't develop RAW, correct lenses, shoot video, do time-lapse, or sync anywhere.

## Requirements

- macOS 14 (Sonoma) or newer. Apple Silicon or Intel.
- A Canon EOS DSLR with USB tethering, set to PTP mode (Menu, wrench, Communication, PTP).
- libgphoto2, only if you build it yourself. The shipped app already includes it.

## Supported cameras

My Canon EOS 7D and a friend's 70D. That is the whole list so far. It should work with other EOS bodies that [libgphoto2 supports](https://www.gphoto.org/proj/libgphoto2/support.php), but I have not tried them. If you run it on another body, [tell me on the repo](https://github.com/chriscantey/film-tether/issues) and I will add it here.

## Install

Grab the latest build from [Releases](https://github.com/chriscantey/film-tether/releases), unzip it, and open it.

## Build from source

Two commands take you from a fresh clone to a running app.

```bash
git clone https://github.com/chriscantey/film-tether.git
cd film-tether && ./scripts/bootstrap.sh
```

The bootstrap installs things on your Mac (Homebrew if you don't already have it, plus libgphoto2 and pkg-config), so feel free to read through it first to see what it does. It then builds, bundles, and launches the app. After that:

```bash
make run             # build, bundle, launch
make dist            # build a distributable .zip
make dist-universal  # universal build (arm64 + x86_64), macOS 14+
make tests           # run the unit tests
make doctor          # diagnostics if something looks off
```

The `make dist` zip vendors libgphoto2, so it runs on a Mac without Homebrew.

One optional extra: `make patched-camlib` builds libgphoto2's PTP driver with a
small fix (kept in `patches/`) for a decode bug that hides the "RAW + L" and
"cRAW + L" quality choices on newer EOS bodies like the R5. Once built, every
`make run`/`make dist` uses it automatically; without it the app still works,
those two Format-menu entries are just missing. Re-run it after
`brew upgrade libgphoto2`.

### If it won't connect

Usually libgphoto2 wins the USB claim and Film Tether connects on the first try. When it doesn't, it's almost always another app already holding the camera. For me that's Preview, which I tend to leave open (Image Capture and Photos can grab it too). Close it and relaunch Film Tether.

## License

MIT for this project's code. See [LICENSE](LICENSE). It dynamically links libgphoto2, which is LGPL 2.1 or later. See [RELINKING.md](RELINKING.md) for the relink steps the LGPL requires.

Canon and EOS are trademarks of Canon Inc. This is a personal project and is not affiliated with or endorsed by Canon.
