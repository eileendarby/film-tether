import Foundation
import Camera
import CGPhoto2
import CoreGraphics
import ImageIO
import Scan

/// FilmTetherDebug, headless CLI for exercising the Camera module without the
/// SwiftUI app. Critical for autonomous testing over SSH: the GUI app needs a
/// window server; this doesn't. Builds via `swift build --product FilmTetherDebug`.
///
/// **Only one process can hold the USB at a time.** Quit the SwiftUI app
/// before running CLI commands and vice versa. If a command hangs or returns
/// -10/-53, run `killall ptpcamerad PTPCamera` and retry.
@main
struct DebugCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            exit(2)
        }
        CameraEnvironment.setup()
        installStderrGphotoLog()  // no-op unless EOS_DEBUG=1
        let cmd = args[1]
        let rest = Array(args.dropFirst(2))
        do {
            try await dispatch(cmd: cmd, rest: rest)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(1)
        }
    }

    @CameraActor
    static func dispatch(cmd: String, rest: [String]) async throws {
        switch cmd {
        case "connect":       try await runConnect()
        case "snapshot":      try await runSnapshot()
        case "widget":
            guard let name = rest.first else { fail("widget needs NAME") }
            try await runWidget(name)
        case "set-widget":
            guard rest.count >= 2 else { fail("set-widget needs NAME VALUE") }
            try await runSetWidget(rest[0], rest[1])
        case "choices":
            guard let name = rest.first else { fail("choices needs NAME") }
            try await runChoices(name)
        case "capture":
            let dir = rest.first ?? defaultCaptureDir()
            try await runCapture(toDir: dir)
        case "lv-start":      try await runLVStart()
        case "lv-stop":       try await runLVStop()
        case "preview":
            let dir = rest.first ?? "/tmp"
            try await runPreview(toDir: dir)
        case "zoomtest":
            let dir = rest.first ?? "/tmp"
            try await runZoomTest(toDir: dir)
        case "zoomcal":
            let dir = rest.first ?? "/tmp"
            try await runZoomCal(toDir: dir)
        case "mf":
            guard let step = rest.first else { fail("mf needs STEP") }
            try await runManualFocus(step)
        case "meter":
            let secs = Int(rest.first ?? "8") ?? 8
            try await runMeter(seconds: secs)
        case "events":
            let secs = Int(rest.first ?? "5") ?? 5
            try await runEvents(seconds: secs)
        case "set-kelvin":
            guard let k = rest.first.flatMap(Int.init) else { fail("set-kelvin needs KELVIN") }
            try await runSetKelvin(k)
        case "detect-crop":   try await runDetectCrop(path: rest.first)
        case "wb-probe":      try await runWhiteBalanceProbe()
        case "crop-profile":  try await runCropProfile(path: rest.first)
        case "edge-votes":
            guard let path = rest.first else { fail("edge-votes needs PATH [WIDTH]") }
            var win: EdgeVoting.DensityWindow?
            if rest.count > 2, case let parts = rest[2].split(separator: ","), parts.count == 2,
               let lo = Double(parts[0]), let hi = Double(parts[1]) {
                win = EdgeVoting.DensityWindow(low: lo, high: hi)
            }
            try runEdgeVotes(path: path, width: rest.count > 1 ? Int(rest[1]) ?? 1024 : 1024,
                             window: win)
        case "crop-region":
            guard let path = rest.first else { fail("crop-region needs PATH [LOW,HIGH]") }
            var band: FrameRegion.Band?
            if rest.count > 1, case let p = rest[1].split(separator: ","), p.count == 2,
               let lo = Double(p[0]), let hi = Double(p[1]) {
                band = FrameRegion.Band(low: lo, high: hi)
            }
            try runCropRegion(path: path, band: band)
        case "crop-sweep":
            guard let path = rest.first else { fail("crop-sweep needs PATH") }
            try runCropSweep(path: path)
        case "crop-plan":
            guard let path = rest.first else { fail("crop-plan needs PATH [SIZE-ID]") }
            let sizeID = rest.count > 1 ? Int(rest[1]) : nil
            try runCropPlan(path: path, sizeID: sizeID,
                            out: rest.count > 2 ? rest[2] : nil)
        case "crop-preview":
            guard let path = rest.first else { fail("crop-preview needs PATH [OUT] [LOW,HIGH]") }
            var previewBand: FrameRegion.Band?
            if rest.count > 2, case let p = rest[2].split(separator: ","), p.count == 2,
               let lo = Double(p[0]), let hi = Double(p[1]) {
                previewBand = FrameRegion.Band(low: lo, high: hi)
            }
            try runCropPreview(path: path, out: rest.count > 1 ? rest[1] : nil,
                               band: previewBand)
        case "clock":         try await runClock()
        case "clock-under-lv": try await runClockUnderLiveView()
        case "clock-watch":
            try await runClockWatch(seconds: Int(rest.first ?? "20") ?? 20)
        case "sync-clock":    try await runSyncClock(local: true)
        case "sync-clock-utc": try await runSyncClock(local: false)
        case "test":          try await runTestSuite()
        case "help", "-h", "--help": printUsage()
        default:              fail("unknown command: \(cmd)")
        }
    }

    // MARK: - Subcommands

    @CameraActor
    static func runConnect() async throws {
        let sess = try await openSession()
        let fw = sess.firmware ?? "(not reported)"
        print("OK firmware=\(fw)")
        sess.close()
    }

    @CameraActor
    static func runSnapshot() async throws {
        let sess = try await openSession(); defer { sess.close() }
        let snap = try await CameraProperties(session: sess).snapshot()
        print("iso=\(snap.iso ?? "?")")
        print("shutter=\(snap.shutter ?? "?")")
        print("aperture=\(snap.aperture ?? "?")")
        print("whitebalance=\(snap.whiteBalance ?? "?")")
        print("kelvin=\(snap.kelvin.map(String.init) ?? "?")")
        print("mode=\(snap.mode ?? "?")")
        print("imageformat=\(snap.imageFormat ?? "?")")
        print("battery=\(snap.battery ?? "?")")
        print("focusmode=\(snap.focusMode ?? "?")")
        if let dt = snap.cameraDateTime {
            print("clock=\(dt) (drift_host=\(Int(dt.timeIntervalSinceNow))s)")
        } else {
            print("clock=?")
        }
    }

    @CameraActor
    static func runWidget(_ name: String) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let v = try await CameraProperties(session: sess).getString(name)
        print("\(name)=\(v)")
    }

    @CameraActor
    static func runSetWidget(_ name: String, _ value: String) async throws {
        let sess = try await openSession(); defer { sess.close() }
        try await CameraProperties(session: sess).setString(name, value: value)
        print("set \(name)=\(value)")
    }

    /// Dump a RADIO/MENU widget's full choice list plus its current value.
    /// Diagnostic for "why is X missing from a picker": the app's menus show
    /// exactly these strings, so this reveals what libgphoto2/the body report.
    @CameraActor
    static func runChoices(_ name: String) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let current = (try? await props.getString(name)) ?? "?"
        let list = try await props.choices(for: name)
        print("\(name) current=\(current) (\(list.count) choices)")
        for (i, c) in list.enumerated() {
            print(String(format: "  [%2d] %@", i, c))
        }
    }

    @CameraActor
    static func runCapture(toDir dirString: String) async throws {
        let dir = URL(fileURLWithPath: NSString(string: dirString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let cap = CameraCapture(session: sess, properties: props)
        let before = Date()
        let result = try await cap.capture(to: dir)
        let dt = Date().timeIntervalSince(before)
        print("OK capture=\(result.path.path) iso=\(result.iso ?? "?") Tv=\(result.shutter ?? "?") Av=\(result.aperture ?? "?") elapsed=\(String(format: "%.1f", dt))s")
    }

    @CameraActor
    static func runLVStart() async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let lv = LiveView(session: sess, properties: props)
        try await lv.start()
        print("OK live view started (mirror up).")
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        try? await lv.stop()
    }

    @CameraActor
    static func runLVStop() async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        try? await props.setString("viewfinder", value: "0")
        try? await props.setString("output", value: "TFT")
        print("OK live view stopped (mirror down)")
    }

    /// Save one live-view JPEG to disk and print its dimensions. The
    /// dimension readback is the ground truth for "what resolution does the
    /// 7D actually stream", and the saved frame lets us eyeball the crop.
    @CameraActor
    static func runPreview(toDir dirString: String) async throws {
        let dir = URL(fileURLWithPath: NSString(string: dirString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let lv = LiveView(session: sess, properties: props)
        try await lv.start()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let data = try await lv.fetchOnePreview()
        try? await lv.stop()
        let url = dir.appendingPathComponent("fs-preview.jpg")
        try data.write(to: url)
        let (w, h) = LiveView.parseJPEGDimensions(data)
        print("OK preview \(w ?? 0)x\(h ?? 0) \(data.count) bytes → \(url.path)")
    }

    /// The headline verification for the camera-side zoom path: capture a
    /// baseline (fit) frame and a 5× sensor-zoom frame, save both, and report
    /// whether the body actually punched in (center-pixel difference). Big
    /// difference = camera-side sensor zoom is live and sharp; ~0 = the body
    /// silently ignored eoszoom (client-crop fallback stays in the app).
    @CameraActor
    static func runZoomTest(toDir dirString: String) async throws {
        let dir = URL(fileURLWithPath: NSString(string: dirString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let lv = LiveView(session: sess, properties: props)
        let lz = LiveZoom(session: sess)
        try await lv.start()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Baseline (fit)
        try? await lz.setZoom(.fit)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let base = try await lv.fetchOnePreview()
        let (bw, bh) = LiveView.parseJPEGDimensions(base)
        try base.write(to: dir.appendingPathComponent("fs-base.jpg"))
        print("baseline: \(bw ?? 0)x\(bh ?? 0)  \(base.count) bytes")

        // Widget introspection, what does eoszoom/eoszoomposition look like now?
        let zoomVal = (try? await props.getString("eoszoom")) ?? "?"
        let posVal = (try? await props.getString("eoszoomposition")) ?? "?"
        print("eoszoom=\(zoomVal)  eoszoomposition=\(posVal)")

        // 5× sensor punch-in
        try await lz.setZoom(.fivex)
        try? await Task.sleep(nanoseconds: 500_000_000)
        let z5 = try await lv.fetchOnePreview()
        let (zw, zh) = LiveView.parseJPEGDimensions(z5)
        try z5.write(to: dir.appendingPathComponent("fs-zoom5.jpg"))
        print("zoom5x:   \(zw ?? 0)x\(zh ?? 0)  \(z5.count) bytes")

        // Verdict
        let diff = LiveZoom.meanCenterPixelDifference(baseline: base, zoomed: z5)
        let verdict = diff > 8.0
            ? "SENSOR ZOOM WORKS, sharp punch-in (the rebuild is good)"
            : "NO PUNCH-IN, body ignored eoszoom; client-crop fallback stays"
        print(String(format: "center-pixel-diff=%.1f  → %@", diff, verdict))

        try? await lz.setZoom(.fit)
        try? await lv.stop()
        print("OK zoomtest complete → \(dir.path) (fs-base.jpg, fs-zoom5.jpg)")
    }

    /// Calibration probe for eoszoomposition. Enters 5× sensor zoom, then
    /// punches in at five known top-left positions (corners + center) in the
    /// 1056×704 fit-frame coordinate space, saving a frame for each. Pull the
    /// frames and SEE where each landed → confirms whether position is honored
    /// and what the coordinate mapping is. Order tested: zoom-first, then
    /// position (the Canon-typical order).
    @CameraActor
    static func runZoomCal(toDir dirString: String) async throws {
        let dir = URL(fileURLWithPath: NSString(string: dirString).expandingTildeInPath)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let lv = LiveView(session: sess, properties: props)
        let lz = LiveZoom(session: sess)
        try await lv.start()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // Fit reference
        try? await lz.setZoom(.fit)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let fit = try await lv.fetchOnePreview()
        try fit.write(to: dir.appendingPathComponent("cal-fit.jpg"))
        print("cal-fit.jpg written (\(fit.count) bytes)")

        // Enter 5× zoom FIRST, then move the position (Canon-typical order).
        try await lz.setZoom(.fivex)
        try? await Task.sleep(nanoseconds: 500_000_000)

        // X-SWEEP to discover the coordinate space. Canon's Evf_ZoomPosition is
        // in the Evf coordinate system (likely ~5184×3456), NOT the 1056×704
        // JPEG. Sweep x across both hypotheses at a fixed small y; whichever
        // value range moves the zoom from left→right edge reveals the true
        // space. y kept low so horizontal motion is unambiguous.
        let yFixed = 200
        let xs = [0, 1500, 3000, 4500, 6000, 7500, 9000, 10000]
        var prevFrame: Data? = nil
        for x in xs {
            do { try await lz.setZoomPosition(x: x, y: yFixed) }
            catch { print("  setZoomPosition(\(x),\(yFixed)) threw: \(error)") }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let frame = try await lv.fetchOnePreview()
            // Consecutive-frame center diff: large while the zoom is moving,
            // ~0 once it clamps at the edge. That clamp x = right edge.
            let diff = prevFrame.map { LiveZoom.meanCenterPixelDifference(baseline: $0, zoomed: frame) } ?? -1
            prevFrame = frame
            let label = String(format: "x%05d", x)
            try frame.write(to: dir.appendingPathComponent("cal-\(label).jpg"))
            print("cal-\(label).jpg  set=(\(x),\(yFixed))  diff_from_prev=\(String(format: "%.1f", diff))  \(frame.count) bytes")
        }

        try? await lz.setZoom(.fit)
        try? await lv.stop()
        print("OK zoomcal complete → \(dir.path)")
    }

    @CameraActor
    static func runManualFocus(_ stepString: String) async throws {
        let step: CameraProperties.ManualFocusStep
        switch stepString.lowercased() {
        case "near-tiny": step = .nearTiny
        case "near-small": step = .nearSmall
        case "near-large": step = .nearLarge
        case "far-tiny": step = .farTiny
        case "far-small": step = .farSmall
        case "far-large": step = .farLarge
        default: fail("mf STEP must be near-tiny|near-small|near-large|far-tiny|far-small|far-large")
        }
        let sess = try await openSession(); defer { sess.close() }
        try await CameraProperties(session: sess).driveManualFocus(step)
        print("OK driveManualFocus(\(step.rawValue))")
    }

    @CameraActor
    static func runMeter(seconds: Int) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let lv = LiveView(session: sess, properties: props)
        let evts = CameraEvents(session: sess)
        try await lv.start()
        print("LV up, draining shutterspeed events for \(seconds)s …")
        let start = Date()
        let deadline = start.addingTimeInterval(TimeInterval(seconds))
        var tvCount = 0
        while Date() < deadline {
            let drained = await evts.drain(budgetMs: 500, perCallMs: 100)
            for e in drained {
                if case .propertyChanged(let name, let value, _) = e,
                   name == "shutterspeed", let value {
                    let elapsed = Date().timeIntervalSince(start)
                    print(String(format: "  +%.2fs Tv=%@", elapsed, value))
                    tvCount += 1
                }
            }
        }
        try? await lv.stop()
        print("OK metered \(tvCount) shutterspeed updates over \(seconds)s")
    }

    @CameraActor
    static func runEvents(seconds: Int) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let lv = LiveView(session: sess, properties: props)
        let evts = CameraEvents(session: sess)
        try await lv.start()
        print("LV up, dumping ALL events for \(seconds)s …")
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var count = 0
        while Date() < deadline {
            let drained = await evts.drain(budgetMs: 500, perCallMs: 100)
            for e in drained {
                count += 1
                print("  \(formatEvent(e))")
            }
        }
        try? await lv.stop()
        print("OK \(count) events drained")
    }

    @CameraActor
    static func runClock() async throws {
        let sess = try await openSession(); defer { sess.close() }
        let snap = try await CameraProperties(session: sess).snapshot()
        guard let dt = snap.cameraDateTime else {
            print("camera clock not readable"); return
        }
        let drift = dt.timeIntervalSinceNow
        print("camera=\(dt)")
        print("host=\(Date())")
        print("drift=\(Int(drift))s")
    }

    /// Exercise the real `setWhiteBalanceKelvin` path, mode switch included.
    ///
    /// `set-widget colortemperature N` deliberately won't do: that writes the
    /// raw widget and skips the mode handling, which is the very thing that was
    /// broken — the app used to set a temperature the body then ignored.
    @CameraActor
    static func runSetKelvin(_ k: Int) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let beforeMode = (try? await props.whiteBalance()) ?? "?"
        let beforeK = (try? await props.getString("colortemperature")) ?? "?"
        print("before: mode=\(beforeMode) colortemperature=\(beforeK)")
        try await props.setWhiteBalanceKelvin(k)
        let afterMode = (try? await props.whiteBalance()) ?? "?"
        let afterK = (try? await props.getString("colortemperature")) ?? "?"
        print("after:  mode=\(afterMode) colortemperature=\(afterK)")
        let modeOK = afterMode.caseInsensitiveCompare(
            CameraProperties.colorTemperatureMode) == .orderedSame
        print(modeOK
              ? "OK mode is Color Temperature, so the value applies"
              : "FAIL mode is still \(afterMode) — the value will be ignored")
    }

    /// Run auto-crop detection against a JPEG on disk, or against a freshly
    /// grabbed live-view frame when no path is given.
    ///
    /// Synthetic tests can only prove the arithmetic; the thresholds have to be
    /// judged against real negatives on the real light table, and this is how
    /// that's done without going through the GUI.
    @CameraActor
    static func runDetectCrop(path: String?) async throws {
        let data: Data
        let source: String
        if let path {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
            source = path
        } else {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            let lv = LiveView(session: sess, properties: props)
            try await lv.start()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            data = try await lv.fetchOnePreview()
            try? await lv.stop()
            source = "live view"
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("could not decode \(source)")
            return
        }
        print("source: \(source)  \(cg.width)x\(cg.height)")

        // Centre-out finder: the one that matters. Starts under the lens and
        // walks out to the first unexposed film in each direction.
        if let f = FrameFinder.detect(in: cg) {
            let r = f.rect
            let px = CGSize(width: r.width * CGFloat(cg.width),
                            height: r.height * CGFloat(cg.height))
            print("CENTRE-OUT:")
            print(String(format: "  rect: x=%.4f y=%.4f w=%.4f h=%.4f  (%.0f x %.0f px)",
                         r.minX, r.minY, r.width, r.height, px.width, px.height))
            print(String(format: "  aspect: %.3f   film base level: %@",
                         Double(max(px.width, px.height) / max(min(px.width, px.height), 1)),
                         f.filmBaseLevel.map { String(format: "%.3f", $0) } ?? "—"))
            if f.unboundedEdges.isEmpty {
                print("  bounded on all four sides")
            } else {
                let names = f.unboundedEdges.map(\.rawValue).sorted().joined(separator: ", ")
                print("  UNBOUNDED on: \(names) — the negative runs past the picture there")
            }
            printCandidates(for: px)
            print("")
        } else {
            print("CENTRE-OUT: no frame found\n")
        }

        // Coarse check: one box around all the film in view, which is a
        // different question from which frame is under the lens.
        guard let result = CropDetector.detect(in: cg, marginFraction: 0.02) else {
            print("WHOLE: no crop detected — the frame looks uniform")
            return
        }
        if !result.unboundedEdges.isEmpty {
            let names = result.unboundedEdges.map(\.rawValue).sorted().joined(separator: ", ")
            print("WHOLE: unbounded on \(names)")
        }
        let r = result.rect
        let px = CGSize(width: r.width * CGFloat(cg.width),
                        height: r.height * CGFloat(cg.height))
        print(String(format: "rect: x=%.4f y=%.4f w=%.4f h=%.4f  (%.0f x %.0f px)",
                     r.minX, r.minY, r.width, r.height, px.width, px.height))
        print(String(format: "coverage: %.1f%%   aspect: %.3f",
                     result.coverage * 100,
                     Double(max(px.width, px.height) / max(min(px.width, px.height), 1))))
        printCandidates(for: px)
    }

    nonisolated static func printCandidates(for px: CGSize) {
        let candidates = FilmSizeMatcher.candidates(forCropSize: px, in: FilmSize.seedCatalog)
        if candidates.isEmpty {
            print("  film size: no catalogue match for that shape")
        } else {
            print("  film size candidates (no scale, so shape only):")
            for c in candidates.prefix(4) {
                print(String(format: "    %-28@ aspect off by %.1f%%",
                             c.size.name as NSString, c.aspectError * 100))
            }
        }
    }

    /// Plan the crop the way the app will: region detection, checked against
    /// the format the session expects, falling back to a built frame when it
    /// disagrees. Draws the result over the picture.
    nonisolated static func runCropPlan(path: String, sizeID: Int?, out: String?) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("could not decode \(path)")
            return
        }
        let expected = sizeID.flatMap { id in FilmSize.seedCatalog.first { $0.id == id } }
        print("\((path as NSString).lastPathComponent)   expecting: \(expected?.name ?? "nothing")")

        if let grid = ColorGrid.sample(cg, width: FrameRegion.analysisWidth),
           let h = CropPlanner.crossBounds(in: grid, around: CGPoint(x: 0.5, y: 0.5)) {
            let px = h.axis == .horizontal ? Double(cg.height) / Double(grid.height)
                                           : Double(cg.width) / Double(grid.width)
            print(String(format: "  cross: film runs %@, picture spans %.0f to %.0f px",
                         h.axis.rawValue as NSString,
                         Double(h.near) * px, Double(h.far) * px))
        } else {
            print("  cross bounds: not found")
        }

        guard let plan = CropPlanner.plan(in: cg, expecting: expected) else {
            print("  no plan")
            return
        }
        let w = plan.rect.width * Double(cg.width), hh = plan.rect.height * Double(cg.height)
        print(String(format: "  %@  %.0f x %.0f px  aspect %.3f  angle %+.2f°%@%@",
                     plan.route.rawValue as NSString, w, hh,
                     max(w, hh) / max(min(w, hh), 1), plan.angle,
                     plan.stableSteps > 0 ? "  stable \(plan.stableSteps)" : "",
                     plan.anchoredEdge.map { "  anchored: \($0.rawValue)" } ?? ""))

        guard let outPath = out else { return }
        let ow = min(1600, cg.width)
        let oh = max(1, Int((Double(cg.height) / Double(cg.width) * Double(ow)).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: ow, height: oh))
        ctx.setLineWidth(1)
        // Green when the detector's own answer was believed, orange when the
        // plan had to be built from what the session knows.
        ctx.setStrokeColor(CGColor(colorSpace: space,
                                   components: plan.route == .detected
                                        ? [0.1, 0.9, 0.3, 1] : [1, 0.6, 0, 1])!)
        let r = plan.rect
        ctx.stroke(CGRect(x: r.minX * Double(ow), y: (1 - r.maxY) * Double(oh),
                          width: r.width * Double(ow), height: r.height * Double(oh)))
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                URL(fileURLWithPath: outPath) as CFURL, "public.jpeg" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image,
            [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
        print("  → \(outPath)")
    }

    /// Sweep one edge of the density band and print the region found at each
    /// step, to see whether the answer is *stable* over a range of thresholds.
    ///
    /// This is the question behind the sweep-and-take-the-median approach: a
    /// real frame should hold its shape while the threshold moves, because the
    /// boundary it stops at is a genuine discontinuity. If no such plateau
    /// exists there is nothing for a median to be robust about, and the whole
    /// family of threshold methods is wrong for that picture.
    ///
    /// Both polarities are swept — unexposed film reads bright on a negative and
    /// dark on a positive, and which one is in front of us isn't known.
    nonisolated static func runCropSweep(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let grid = ColorGrid.sample(cg, width: FrameRegion.analysisWidth) else {
            print("could not decode \(path)")
            return
        }
        print("source: \((path as NSString).lastPathComponent)  \(cg.width)x\(cg.height)")

        var centre: [Double] = []
        for y in (grid.height * 3 / 8)..<(grid.height * 5 / 8) {
            for x in (grid.width * 3 / 8)..<(grid.width * 5 / 8) {
                centre.append(grid[x, y].luminance)
            }
        }
        centre.sort()
        let picture = centre[centre.count / 2]
        print(String(format: "  picture level %.3f", picture))

        for rising in [true, false] {
            // rising: the band's *upper* edge moves up, with the lower edge held
            // below the picture — the arrangement for unexposed film that reads
            // brighter than the picture. falling: the mirror image.
            print(rising ? "\n  upper edge sweeping up (unexposed film brighter)"
                         : "\n  lower edge sweeping down (unexposed film darker)")
            print("   thresh  coverage   x      y      w      h     angle")
            var t = rising ? picture + 0.02 : picture - 0.02
            while rising ? t <= 0.99 : t >= 0.01 {
                let band = rising
                    ? FrameRegion.Band(low: 0.0, high: t)
                    : FrameRegion.Band(low: t, high: 1.0)
                if let r = FrameRegion.detect(in: grid, around: CGPoint(x: 0.5, y: 0.5), band: band) {
                    print(String(format: "   %.3f   %5.1f%%   %.3f  %.3f  %.3f  %.3f  %+.2f",
                                 t, r.coverage * 100,
                                 r.center.x, r.center.y, r.size.width, r.size.height, r.angle))
                } else {
                    print(String(format: "   %.3f      —", t))
                }
                t += rising ? 0.02 : -0.02
            }
        }
    }

    /// Grow the frame as a connected region and report the oriented rectangle.
    nonisolated static func runCropRegion(path: String, band: FrameRegion.Band?) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let grid = ColorGrid.sample(cg, width: FrameRegion.analysisWidth) else {
            print("could not decode \(path)")
            return
        }
        print("source: \((path as NSString).lastPathComponent)  \(cg.width)x\(cg.height)")

        func percentiles(_ v: [Double]) -> String {
            let s = v.sorted()
            func q(_ f: Double) -> Double { s[min(s.count - 1, Int(Double(s.count - 1) * f))] }
            return String(format: "p05 %.3f  p50 %.3f  p95 %.3f", q(0.05), q(0.50), q(0.95))
        }
        var all: [Double] = [], centre: [Double] = []
        for y in 0..<grid.height {
            for x in 0..<grid.width {
                let v = grid[x, y].luminance
                all.append(v)
                if y >= grid.height * 3 / 8, y < grid.height * 5 / 8,
                   x >= grid.width * 3 / 8, x < grid.width * 5 / 8 { centre.append(v) }
            }
        }
        print("  whole:  \(percentiles(all))")
        print("  centre: \(percentiles(centre))   ← picture, by assumption")

        let use = band ?? autoBand(all: all, centre: centre)
        print(String(format: "  band %.3f–%.3f%@", use.low, use.high,
                     band == nil ? " (derived)" : " (given)"))

        guard let r = FrameRegion.detect(in: cg, band: use) else {
            print("  no region found")
            return
        }
        let px = CGSize(width: r.size.width * Double(cg.width),
                        height: r.size.height * Double(cg.height))
        print(String(format: "  centre (%.4f, %.4f)  size %.0f x %.0f px  angle %+.2f°",
                     r.center.x, r.center.y, px.width, px.height, r.angle))
        print(String(format: "  aspect %.3f   coverage %.1f%%   %@",
                     max(px.width, px.height) / max(min(px.width, px.height), 1),
                     r.coverage * 100,
                     r.touchesBorder ? "touches the picture's border" : "wholly inside the picture"))
        printCandidates(for: px)
    }

    /// Band of densities that exposed film occupies: above the holder, below the
    /// unexposed base. Provisional — the reference implementation this follows
    /// leaves both bounds as operator sliders rather than deriving them.
    nonisolated static func autoBand(all: [Double], centre: [Double]) -> FrameRegion.Band {
        let s = all.sorted(), c = centre.sorted()
        func q(_ v: [Double], _ f: Double) -> Double {
            v[min(v.count - 1, Int(Double(v.count - 1) * f))]
        }
        let pictureLow = q(c, 0.02), pictureHigh = q(c, 0.98)
        let base = q(s, 0.97)
        return FrameRegion.Band(
            low: pictureLow / 2,
            high: pictureHigh + (max(base, pictureHigh) - pictureHigh) / 2
        )
    }

    /// Pick a density band to look across.
    ///
    /// It has to sit between the picture's own tones and the film base's, so
    /// that the only transitions left are the ones crossing from picture to
    /// base. The picture is sampled from the middle of the frame, which is under
    /// the lens and so is picture by assumption; the base is taken as a high
    /// percentile, being the brightest thing present in quantity on a negative.
    ///
    /// Provisional. Derived this way the band is wider than one chosen by hand
    /// for a given negative, and lets more of the photograph's own edges back
    /// into the vote.
    nonisolated static func autoWindow(for grid: ColorGrid) -> EdgeVoting.DensityWindow {
        var all: [Double] = []
        all.reserveCapacity(grid.width * grid.height)
        for y in 0..<grid.height {
            for x in 0..<grid.width { all.append(grid[x, y].luminance) }
        }
        all.sort()
        var centre: [Double] = []
        for y in (grid.height * 3 / 8)..<(grid.height * 5 / 8) {
            for x in (grid.width * 3 / 8)..<(grid.width * 5 / 8) {
                centre.append(grid[x, y].luminance)
            }
        }
        centre.sort()
        guard !all.isEmpty, !centre.isEmpty else {
            return EdgeVoting.DensityWindow(low: 0, high: 1)
        }
        let picture = centre[centre.count / 2]
        let base = all[Int(Double(all.count - 1) * 0.95)]
        let gap = base - picture
        return EdgeVoting.DensityWindow(low: picture + gap * 0.4, high: base + gap * 0.4)
    }

    /// Rank the candidate straight edges by how many lines vote for them.
    ///
    /// Prints positions in the *source* image's pixels as well as the working
    /// grid's, so a candidate can be checked against a coordinate read off the
    /// original in an editor.
    nonisolated static func runEdgeVotes(path: String, width: Int,
                                         window: EdgeVoting.DensityWindow? = nil) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let grid = ColorGrid.sample(cg, width: width) else {
            print("could not decode \(path)")
            return
        }
        print("source: \((path as NSString).lastPathComponent)  \(cg.width)x\(cg.height)  →  grid \(grid.width)x\(grid.height)")
        var all: [Double] = []
        for y in 0..<grid.height { for x in 0..<grid.width { all.append(grid[x, y].luminance) } }
        all.sort()
        func q(_ f: Double) -> Double { all[min(all.count - 1, Int(Double(all.count - 1) * f))] }
        print(String(format: "  luminance p01 %.3f  p10 %.3f  p50 %.3f  p75 %.3f  p90 %.3f  p95 %.3f  p99 %.3f  max %.3f",
                     q(0.01), q(0.10), q(0.50), q(0.75), q(0.90), q(0.95), q(0.99), q(1.0)))
        // Derive the band: it has to sit between the picture's own tones and the
        // film base's. The picture is sampled from the middle of the frame,
        // which is under the lens and so is picture by assumption; the base is
        // taken as a high percentile, being the brightest thing present in
        // quantity on a negative.
        let auto = autoWindow(for: grid)
        print(String(format: "  auto window %.3f–%.3f", auto.low, auto.high))
        let useWindow = window ?? auto

        for orientation in [EdgeVoting.Orientation.vertical, .horizontal] {
            let axisLen = orientation == .vertical ? grid.width : grid.height
            let scale = orientation == .vertical
                ? Double(cg.width) / Double(grid.width)
                : Double(cg.height) / Double(grid.height)
            let raw = EdgeVoting.candidates(in: grid, orientation: orientation,
                                            window: useWindow, minCoverage: 0.50)
            let found = EdgeVoting.merged(raw, within: max(2, axisLen / 200),
                                          nearest: axisLen / 2)
            print("\n\(orientation.rawValue.uppercased()) edges — \(raw.count) raw → \(found.count) merged  (≥50% agreement)")
            print("   grid   source px   agreement  strength")
            for c in found.sorted(by: { $0.strength > $1.strength }).prefix(14) {
                print(String(format: "  %5d   %8.0f   %8.1f%%   %.4f",
                             c.index, Double(c.index) * scale, c.coverage * 100, c.strength))
            }
        }
    }
    /// Write a JPEG with every detector's crop drawn on it, one colour each.
    ///
    /// Numbers say a crop is 5248×5122; only a picture says whether those are
    /// the *right* 5248×5122. Drawing all three together is also the only
    /// straightforward way to see where they agree — agreement between methods
    /// that fail differently is worth more than any one of them being confident.
    ///
    ///   red    FrameFinder   line profiles, walked out from the centre
    ///   blue   EdgeVoting    aligned density shifts, bracketing the centre
    ///   green  FrameRegion   connected region, oriented rectangle
    nonisolated static func runCropPreview(path: String, out: String?,
                                           band: FrameRegion.Band? = nil) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("could not decode \(path)")
            return
        }
        let name = (path as NSString).lastPathComponent
        print(name)

        let w = min(1600, cg.width)
        let h = max(1, Int((Double(cg.height) / Double(cg.width) * Double(w)).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { print("  could not make a context"); return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setLineWidth(1)

        func color(_ r: Double, _ g: Double, _ b: Double) -> CGColor {
            CGColor(colorSpace: space, components: [r, g, b, 1])!
        }
        /// Normalized y-down rect to the context's y-up pixels.
        func draw(_ r: CGRect, _ c: CGColor) {
            ctx.setStrokeColor(c)
            ctx.stroke(CGRect(x: r.minX * Double(w), y: (1 - r.maxY) * Double(h),
                              width: r.width * Double(w), height: r.height * Double(h)))
        }
        func report(_ label: String, _ r: CGRect, _ extra: String = "") {
            let px = CGSize(width: r.width * Double(cg.width), height: r.height * Double(cg.height))
            print(String(format: "  %-12@ %5.0f x %5.0f px  aspect %.3f%@",
                         label as NSString, px.width, px.height,
                         max(px.width, px.height) / max(min(px.width, px.height), 1),
                         extra as NSString))
        }

        // Red — line profiles walked out from the centre.
        if let f = FrameFinder.detect(in: cg) {
            draw(f.rect, color(1, 0.15, 0.15))
            report("FrameFinder", f.rect, f.unboundedEdges.isEmpty ? "  bounded"
                   : "  unbounded: " + f.unboundedEdges.map(\.rawValue).sorted().joined(separator: ","))
        } else {
            print("  FrameFinder  no frame found")
        }

        guard let grid = ColorGrid.sample(cg, width: 1024) else { return }

        // Blue — the nearest voted edge either side of the centre on each axis.
        // Nearest rather than strongest: that is the same rule the centre-out
        // walk uses, so the two differ only in how an edge is recognised.
        let win = autoWindow(for: grid)
        func bracket(_ o: EdgeVoting.Orientation, _ extent: Int) -> (Int, Int) {
            let raw = EdgeVoting.candidates(in: grid, orientation: o,
                                            window: win, minCoverage: 0.50)
            let found = EdgeVoting.merged(raw, within: max(2, extent / 200),
                                          nearest: extent / 2)
            let mid = extent / 2
            // Strongest on each side, not nearest. Nearest picks whatever the
            // photograph happens to have closest to the middle, which on an
            // interior is a doorframe — measured, and it produced a crop of a
            // picture hanging on a wall inside the negative.
            let lo = found.filter { $0.index < mid }.max { $0.strength < $1.strength }
            let hi = found.filter { $0.index > mid }.max { $0.strength < $1.strength }
            return (lo?.index ?? 0, hi?.index ?? (extent - 1))
        }
        let (vl, vr) = bracket(.vertical, grid.width)
        let (ht, hb) = bracket(.horizontal, grid.height)
        let voted = CGRect(
            x: Double(vl) / Double(grid.width), y: Double(ht) / Double(grid.height),
            width: Double(vr - vl) / Double(grid.width),
            height: Double(hb - ht) / Double(grid.height))
        if voted.width > 0, voted.height > 0 {
            draw(voted, color(0.25, 0.45, 1))
            report("EdgeVoting", voted)
        } else {
            print("  EdgeVoting   no bracketing edges")
        }

        // Green — connected region. Drawn as the oriented quadrilateral it
        // actually produces, not an upright box: the rotation is the thing this
        // method has that the others don't, and squaring it off would hide it.
        var all: [Double] = [], centre: [Double] = []
        for y in 0..<grid.height {
            for x in 0..<grid.width {
                let v = grid[x, y].luminance
                all.append(v)
                if y >= grid.height * 3 / 8, y < grid.height * 5 / 8,
                   x >= grid.width * 3 / 8, x < grid.width * 5 / 8 { centre.append(v) }
            }
        }
        let swept = band.map { FrameRegion.detect(in: cg, band: $0).map {
            FrameRegion.SweepResult(frame: $0, stableSteps: 0, thresholds: 0...0) } }
            ?? FrameRegion.detectBySweep(in: cg)
        if let s = swept {
            let r = s.frame
            let cxp = r.center.x * Double(w), cyp = (1 - r.center.y) * Double(h)
            let hw = r.size.width * Double(w) / 2, hh = r.size.height * Double(h) / 2
            // Negated: the result's angle is clockwise in a y-down picture, the
            // context is y-up.
            let a = -r.angle * .pi / 180
            let corners = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map {
                CGPoint(x: cxp + $0.0 * cos(a) - $0.1 * sin(a),
                        y: cyp + $0.0 * sin(a) + $0.1 * cos(a))
            }
            ctx.setStrokeColor(color(0.1, 0.9, 0.3))
            ctx.beginPath()
            ctx.move(to: corners[3])
            for c in corners { ctx.addLine(to: c) }
            ctx.strokePath()
            report("FrameRegion",
                   CGRect(x: 0, y: 0, width: r.size.width, height: r.size.height),
                   String(format: "  angle %+.2f°  stable over %d thresholds (%.2f–%.2f)%@",
                          r.angle, s.stableSteps, s.thresholds.lowerBound, s.thresholds.upperBound,
                          r.touchesBorder ? "  touches border" : ""))
        } else {
            print("  FrameRegion  no stable region — no threshold answer exists here")
        }

        guard let image = ctx.makeImage() else { print("  could not render"); return }
        let outPath = out ?? ((path as NSString).deletingPathExtension + "-crop.jpg")
        guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: outPath) as CFURL, "public.jpeg" as CFString, 1, nil) else {
            print("  could not open \(outPath)")
            return
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { print("  could not write \(outPath)"); return }
        print("  → \(outPath)")
    }


    /// Print the row and column profiles a crop detector sees, as bars.
    ///
    /// Thresholds for "this line is unexposed film" cannot be reasoned out from
    /// first principles — they depend on the film stock, the light table and the
    /// exposure. This shows the actual populations so they can be read off, and
    /// makes it obvious when two of them overlap.
    @CameraActor
    static func runCropProfile(path: String?) async throws {
        let data: Data
        let source: String
        if let path {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
            source = (path as NSString).lastPathComponent
        } else {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            let lv = LiveView(session: sess, properties: props)
            try await lv.start()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            data = try await lv.fetchOnePreview()
            try? await lv.stop()
            source = "live view"
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let grid = ColorGrid.sample(cg, width: 192) else {
            print("could not decode \(source)")
            return
        }
        print("source: \(source)  \(cg.width)x\(cg.height)  →  grid \(grid.width)x\(grid.height)")

        // The walk as the finder actually runs it: each axis measured over the
        // extent the other one found, which is not the same profile as the
        // whole-image one printed below.
        let cx = grid.width / 2, cy = grid.height / 2
        let seed = max(1, grid.height / 4)
        let cols = FilmProfile.build(from: grid, axis: .vertical,
                                     across: max(0, cy - seed)...min(grid.height - 1, cy + seed))
        print("\nWALK — columns, seeded over the middle band of rows")
        print(FrameFinder.describeWalk(cols, from: cx), terminator: "")
        if let (l, r) = FrameFinder.walkBothWays(cols, from: cx) {
            let rows = FilmProfile.build(from: grid, axis: .horizontal,
                                         across: l.index...r.index)
            print("\nWALK — rows, over columns \(l.index)...\(r.index)")
            print(FrameFinder.describeWalk(rows, from: cy), terminator: "")
        }

        for axis in [FilmProfile.Axis.vertical, .horizontal] {
            let p = FilmProfile.build(from: grid, axis: axis)
            let name = axis == .vertical ? "COLUMNS (x →)" : "ROWS (y ↓)"
            print("\n\(name)  \(p.count) lines")
            print(String(format: "  level    median %.3f  p05 %.3f  p95 %.3f",
                         p.median(\.level), p.quantile(0.05, \.level), p.quantile(0.95, \.level)))
            print(String(format: "  roughness median %.4f  p05 %.4f  p95 %.4f",
                         p.median(\.roughness), p.quantile(0.05, \.roughness),
                         p.quantile(0.95, \.roughness)))
            print(String(format: "  deviation median %.4f", p.median(\.deviation)))

            let maxRough = max(p.quantile(1.0, \.roughness), 1e-9)
            print("   idx  level                     roughness")
            // Every other line keeps the table readable while still resolving a
            // band a few lines thick.
            for i in stride(from: 0, to: p.count, by: 2) {
                let l = p[i]
                print(String(format: "  %4d  %.3f %@  %.4f %@",
                             i, l.level, bar(l.level, max: 1.0, width: 20) as NSString,
                             l.roughness, bar(l.roughness, max: maxRough, width: 20) as NSString))
            }
        }
    }

    nonisolated static func bar(_ v: Double, max m: Double, width: Int) -> String {
        let n = Int((min(max(v, 0), m) / m * Double(width)).rounded())
        return String(repeating: "█", count: n) + String(repeating: "·", count: width - n)
    }

    /// Measure how this body's rendered live-view frames respond to a change in
    /// `colortemperature`, so the eyedropper's estimate rests on a measurement
    /// rather than on textbook blackbody physics.
    ///
    /// The theory says `ln(R/B)` should be linear in `1/T` with a slope of about
    /// 7993 K (Wien, at 450/600 nm). What actually comes off the camera is a
    /// rendered JPEG — tone curve, saturation, picture style — so the real slope
    /// is the thing worth knowing. The whatever-is-under-the-lens cast is a
    /// constant offset in log space and drops out of a slope fit, so this can be
    /// run with a negative in place; it does not need a grey card.
    ///
    /// Restores the body's original mode and temperature on the way out.
    @CameraActor
    static func runWhiteBalanceProbe() async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)

        let originalMode = (try? await props.whiteBalance()) ?? ""
        let originalK = (try? await props.getString("colortemperature")) ?? ""
        print("before: mode=\(originalMode) colortemperature=\(originalK)")

        let lv = LiveView(session: sess, properties: props)
        try await lv.start()
        defer { Task { @CameraActor in try? await lv.stop() } }
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        let temperatures = [2500, 3200, 4000, 5000, 6500, 8000, 10000]
        var points: [(inverseT: Double, logRatio: Double)] = []

        print("\n     K    R      G      B       ln(R/B)")
        for k in temperatures {
            try await props.setWhiteBalanceKelvin(k)
            // The body needs a moment to render frames under the new setting,
            // and the first frames after a property write are often the old
            // ones still in flight — hence the sleep, then a discarded frame.
            try? await Task.sleep(nanoseconds: 900_000_000)
            _ = try? await lv.fetchOnePreview()
            guard let data = try? await lv.fetchOnePreview(),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let s = PixelSampler.averageColor(
                    in: cg, atNormalized: CGPoint(x: 0.5, y: 0.5), patchSize: 400)
            else {
                print(String(format: "%6d    (no frame)", k))
                continue
            }
            let r = WhiteBalanceEstimate.linearize(s.red)
            let b = WhiteBalanceEstimate.linearize(s.blue)
            guard r > 0, b > 0 else {
                print(String(format: "%6d    (channel empty: R=%.3f B=%.3f)", k, s.red, s.blue))
                continue
            }
            let logRatio = Foundation.log(r / b)
            points.append((1.0 / Double(k), logRatio))
            print(String(format: "%6d  %.3f  %.3f  %.3f   %+.4f",
                         k, s.red, s.green, s.blue, logRatio))
        }

        // Restore, best effort — leaving the body somewhere it wasn't would be
        // rude, and would silently change the next capture.
        if let k = Int(originalK) { try? await props.setWhiteBalanceKelvin(k) }
        if !originalMode.isEmpty { try? await props.setWhiteBalance(originalMode) }

        guard points.count >= 3 else {
            print("\nnot enough usable points to fit")
            return
        }
        // Least squares on ln(R/B) = slope·(1/T) + intercept. The slope is
        // `WhiteBalanceEstimate.responseConstant`.
        let n = Double(points.count)
        let sx = points.reduce(0) { $0 + $1.inverseT }
        let sy = points.reduce(0) { $0 + $1.logRatio }
        let sxx = points.reduce(0) { $0 + $1.inverseT * $1.inverseT }
        let sxy = points.reduce(0) { $0 + $1.inverseT * $1.logRatio }
        let syy = points.reduce(0) { $0 + $1.logRatio * $1.logRatio }
        let denom = n * sxx - sx * sx
        guard denom != 0 else { print("\ndegenerate fit"); return }
        let slope = (n * sxy - sx * sy) / denom
        let r2num = n * sxy - sx * sy
        let r2 = (r2num * r2num) / (denom * (n * syy - sy * sy))

        print(String(format: "\nfit: slope = %.1f K   R² = %.4f   (n = %d)",
                     slope, r2, points.count))
        print(String(format: "currently compiled in: %.1f K",
                     WhiteBalanceEstimate.responseConstant))
        print("Wien at 450/600nm would be 7993 K")
    }

    /// Does the camera's clock reading actually advance within a single
    /// session, or is it cached at the value from the first read?
    ///
    /// The app holds one long-lived session, unlike the one-shot `clock`
    /// command which opens a fresh session each time — so a value that is
    /// cached per-session would look fine from the CLI and be frozen in the
    /// app. Prints the reading against host time once a second; a healthy clock
    /// keeps `delta` constant, a cached one makes it grow by one second per
    /// second.
    @CameraActor
    static func runClockWatch(seconds: Int) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        print("elapsed  camera-reading        delta-vs-host")
        let start = Date()
        var first: Date?
        while Date().timeIntervalSince(start) < TimeInterval(seconds) {
            let snap = try? await props.snapshot()
            if let cam = snap?.cameraDateTime {
                if first == nil { first = cam }
                let delta = cam.timeIntervalSinceNow
                print(String(format: "%5.1fs   %@   %+.0fs",
                             Date().timeIntervalSince(start),
                             ISO8601DateFormatter().string(from: cam),
                             delta))
            } else {
                print("   ?     (clock unreadable)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if let first, let last = (try? await props.snapshot())?.cameraDateTime {
            let advanced = last.timeIntervalSince(first)
            print(String(format: "\ncamera clock advanced %.0fs over %ds of wall time — %@",
                         advanced, seconds,
                         advanced < Double(seconds) / 2
                            ? "STALE, cached per session"
                            : "live"))
        }
    }

    /// Does a clock-sync write survive an active live-view stream?
    ///
    /// Written to settle exactly that question: the footer's "click to re-sync"
    /// appeared to do nothing during live view, and the suspicion was that the
    /// 30 FPS preview traffic starves the write of the USB pipe. Runs the same
    /// write twice — once competing with the stream, once with the frame loop
    /// paused via `withPriority`, which is how every other camera write in the
    /// app is issued.
    @CameraActor
    static func runClockUnderLiveView() async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        let lv = LiveView(session: sess, properties: props)

        // Skew the clock first so a successful write is visible in the readback
        // rather than being indistinguishable from "already correct".
        try await props.syncDateTimeToHostLocal(tzOffsetMinutes: -37)
        let skewed = (try? await props.snapshot().cameraDateTime).flatMap { $0 }
        print("skewed clock to \(skewed.map { Int($0.timeIntervalSinceNow) } ?? 0)s vs host")

        try await lv.start()
        try? await Task.sleep(nanoseconds: 2_000_000_000)  // let frames flow
        print("live view up, frames streaming")

        print("\n--- write WITHOUT priority (competing with the stream) ---")
        var unprioritisedError: String?
        do {
            try await props.syncDateTimeToHostLocal()
        } catch {
            unprioritisedError = String(describing: error)
        }
        let afterPlain = (try? await props.snapshot().cameraDateTime).flatMap { $0 }
        let driftPlain = afterPlain.map { abs(Int($0.timeIntervalSinceNow)) }
        print("  error: \(unprioritisedError ?? "none")")
        print("  drift after: \(driftPlain.map(String.init) ?? "?")s")

        // Re-skew so the second attempt has something to correct.
        try? await lv.withPriority { try await props.syncDateTimeToHostLocal(tzOffsetMinutes: -37) }

        print("\n--- write WITH priority (frame loop paused) ---")
        var prioritisedError: String?
        do {
            try await lv.withPriority { try await props.syncDateTimeToHostLocal() }
        } catch {
            prioritisedError = String(describing: error)
        }
        let afterPriority = (try? await props.snapshot().cameraDateTime).flatMap { $0 }
        let driftPriority = afterPriority.map { abs(Int($0.timeIntervalSinceNow)) }
        print("  error: \(prioritisedError ?? "none")")
        print("  drift after: \(driftPriority.map(String.init) ?? "?")s")

        try? await lv.stop()
        // Leave the camera correct regardless of what the test proved.
        try? await props.syncDateTimeToHostLocal()
        print("\ncamera clock restored")
    }

    @CameraActor
    static func runSyncClock(local: Bool) async throws {
        let sess = try await openSession(); defer { sess.close() }
        let props = CameraProperties(session: sess)
        if local {
            try await props.syncDateTimeToHostLocal()
            print("OK synced camera to host LOCAL wall clock (\(Date()))")
        } else {
            try await props.syncDateTimeToHost()
            print("OK synced camera to host UTC (\(Date()))")
        }
    }

    // MARK: - Test suite

    @CameraActor
    static func runTestSuite() async throws {
        print("===Film Tether debug test suite===")
        print("start=\(Date())")
        var results: [(String, Bool, String)] = []

        results.append(await runStep("connect") {
            let sess = try await openSession()
            let fw = sess.firmware ?? "?"
            sess.close()
            return "firmware=\(fw)"
        })

        results.append(await runStep("snapshot") {
            let sess = try await openSession(); defer { sess.close() }
            let snap = try await CameraProperties(session: sess).snapshot()
            return "iso=\(snap.iso ?? "?") Tv=\(snap.shutter ?? "?") mode=\(snap.mode ?? "?")"
        })

        results.append(await runStep("clock-sync-local") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            try await props.syncDateTimeToHostLocal()
            let snap = try await props.snapshot()
            guard let dt = snap.cameraDateTime else {
                throw DebugError("no clock readback after sync")
            }
            let drift = abs(dt.timeIntervalSinceNow)
            guard drift < 5 else {
                throw DebugError("drift \(Int(drift))s > 5s after sync")
            }
            return "drift_after=\(Int(drift))s"
        })

        results.append(await runStep("lv-frame") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            let lv = LiveView(session: sess, properties: props)
            try await lv.start()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let frame = try await lv.fetchOnePreview()
            try? await lv.stop()
            guard frame.count > 1000 else {
                throw DebugError("tiny frame \(frame.count) bytes")
            }
            return "bytes=\(frame.count)"
        })

        results.append(await runStep("metering-events") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            let lv = LiveView(session: sess, properties: props)
            let evts = CameraEvents(session: sess)
            try await lv.start()
            let deadline = Date().addingTimeInterval(4)
            var tvCount = 0
            var lastTv: String? = nil
            while Date() < deadline {
                let drained = await evts.drain(budgetMs: 500, perCallMs: 100)
                for e in drained {
                    if case .propertyChanged(let name, let value, _) = e,
                       name == "shutterspeed", let value {
                        tvCount += 1
                        lastTv = value
                    }
                }
            }
            try? await lv.stop()
            guard tvCount > 0 else {
                throw DebugError("no Tv events seen in 4s")
            }
            return "tv_updates=\(tvCount) last=\(lastTv ?? "?")"
        })

        let captureDir = URL(fileURLWithPath: NSString(string: defaultCaptureDir()).expandingTildeInPath)
        results.append(await runStep("capture-immediate") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            let cap = CameraCapture(session: sess, properties: props)
            let result = try await cap.capture(to: captureDir, filenamePattern: "DEBUG_{ymd}_{hms}_{seq}.{ext}")
            let attrs = try FileManager.default.attributesOfItem(atPath: result.path.path)
            let size = (attrs[.size] as? Int) ?? 0
            guard size > 1_000_000 else {
                throw DebugError("RAW too small (\(size) bytes)")
            }
            return "path=\(result.path.lastPathComponent) bytes=\(size) iso=\(result.iso ?? "?") Tv=\(result.shutter ?? "?")"
        })

        results.append(await runStep("manual-focus") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            let lv = LiveView(session: sess, properties: props)
            try await lv.start()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            try await props.driveManualFocus(.nearTiny)
            try? await Task.sleep(nanoseconds: 500_000_000)
            try await props.driveManualFocus(.farTiny)
            try? await lv.stop()
            return "near-tiny + far-tiny written without error"
        })

        results.append(await runStep("teardown") {
            let sess = try await openSession(); defer { sess.close() }
            let props = CameraProperties(session: sess)
            try? await props.setString("viewfinder", value: "0")
            try? await props.setString("output", value: "TFT")
            return "viewfinder=0 + output=TFT written (mirror should be down)"
        })

        printResults(results)
    }

    // MARK: - Helpers

    @CameraActor
    static func runStep(_ name: String, _ body: () async throws -> String) async -> (String, Bool, String) {
        do {
            let evidence = try await body()
            return (name, true, evidence)
        } catch {
            return (name, false, "\(error)")
        }
    }

    static func printResults(_ results: [(String, Bool, String)]) {
        print("\n===RESULTS===")
        var pass = 0, fail = 0
        for (name, ok, evidence) in results {
            let tag = ok ? "PASS" : "FAIL"
            print("\(tag) \(name), \(evidence)")
            if ok { pass += 1 } else { fail += 1 }
        }
        print("\nsummary: \(pass) passed, \(fail) failed, total \(results.count)")
        print("end=\(Date())")
    }

    /// With EOS_DEBUG=1, pipe libgphoto2's internal logging straight to stderr.
    /// The GUI app bridges to unified logging instead (CameraLog); for a
    /// headless CLI, stderr is greppable and needs no `log show`.
    static func installStderrGphotoLog() {
        guard ProcessInfo.processInfo.environment["EOS_DEBUG"] == "1" else { return }
        gp_log_add_func(GP_LOG_DEBUG, { _, domain, message, _ in
            let d = domain.map { String(cString: $0) } ?? "?"
            let m = message.map { String(cString: $0) } ?? "?"
            FileHandle.standardError.write(Data("gp[\(d)] \(m)\n".utf8))
        }, nil)
    }

    @CameraActor
    static func openSession() async throws -> CameraSession {
        let sess = try CameraSession()
        try await sess.open()
        return sess
    }

    static func formatEvent(_ e: CameraEvents.Event) -> String {
        switch e {
        case .timeout: return "timeout"
        case .fileAdded(let folder, let name): return "FILE_ADDED \(folder)/\(name)"
        case .captureComplete: return "CAPTURE_COMPLETE"
        case .propertyChanged(let n, let v, let raw):
            if let n, let v { return "PROP \(n) = \(v)" }
            return "PROP_RAW \(raw)"
        case .unknown(let raw): return "UNKNOWN \(raw)"
        }
    }

    static func defaultCaptureDir() -> String {
        return NSString(string: "~/Pictures/Film Tether").expandingTildeInPath
    }

    static func printUsage() {
        print("""
        FilmTetherDebug, headless CLI for the Camera module.

        Usage: filmtether-debug <command> [args]

        Commands:
          connect                 Open + close session, print firmware
          snapshot                Dump current property snapshot
          widget NAME             Read a raw widget value
          set-widget NAME VALUE   Write a raw widget value
          choices NAME            List a RADIO/MENU widget's choices + current value
          capture [DIR]           Fire the shutter + download the RAW (and JPEG, if RAW+JPEG)
          lv-start                Engage live view briefly (sanity check)
          lv-stop                 Disengage live view (mirror down)
          preview [DIR]           Save one LV JPEG (default /tmp) + print its dimensions
          zoomtest [DIR]          Baseline vs 5x sensor-zoom frames + punch-in verdict
          mf STEP                 Manual focus: near-tiny|near-small|near-large|far-tiny|far-small|far-large
          meter [SECONDS]         LV + drain shutterspeed events (default 8s)
          events [SECONDS]        LV + dump ALL events (default 5s)
          set-kelvin K            Set WB temperature the way the app does (mode + value)
          detect-crop [PATH]      Auto-crop a JPEG, or one freshly grabbed LV frame
          crop-profile [PATH]     Row/column profiles + the edge walk, as bars
          wb-probe                Sweep colour temperature under LV, fit the body's response
          clock                   Read camera clock + host drift
          sync-clock              Sync camera to host LOCAL wall clock
          sync-clock-utc          Sync camera to host UTC (legacy)
          test                    Run full automated test suite

        Reminder: only one process can hold the USB at a time. Quit the
        SwiftUI Film Tether app before running CLI commands. If a command
        hangs or returns -10/-53, run: killall ptpcamerad PTPCamera
        """)
    }

    static func fail(_ msg: String) -> Never {
        FileHandle.standardError.write(Data("ERROR: \(msg)\n".utf8))
        exit(2)
    }

    struct DebugError: LocalizedError {
        let message: String
        init(_ m: String) { self.message = m }
        var errorDescription: String? { message }
    }
}
