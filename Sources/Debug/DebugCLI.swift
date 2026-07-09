import Foundation
import Camera
import CGPhoto2

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
        case "clock":         try await runClock()
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
          capture [DIR]           Fire the shutter + download the RAW (and JPEG, if RAW+JPEG)
          lv-start                Engage live view briefly (sanity check)
          lv-stop                 Disengage live view (mirror down)
          preview [DIR]           Save one LV JPEG (default /tmp) + print its dimensions
          zoomtest [DIR]          Baseline vs 5x sensor-zoom frames + punch-in verdict
          mf STEP                 Manual focus: near-tiny|near-small|near-large|far-tiny|far-small|far-large
          meter [SECONDS]         LV + drain shutterspeed events (default 8s)
          events [SECONDS]        LV + dump ALL events (default 5s)
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
