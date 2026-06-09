import Foundation
import CoreFoundation

/// A `SerialExecutor` that pins all work to a single dedicated `pthread` running a `CFRunLoop`.
///
/// Why this exists: Swift's custom global actor (`CameraActor`) guarantees serial execution but
/// does NOT guarantee thread affinity, the default executor hops between OS threads at suspension
/// points. libgphoto2 sits on libusb-1.0 (thread-sensitive sync transfers) and uses `signal()`
/// masking that is per-thread. Without pinning, "EIO halfway through a 200-frame live-view session"
/// is the failure mode.
public final class PinnedThreadExecutor: SerialExecutor, @unchecked Sendable {
    private let runLoop: CFRunLoop
    private let thread: Thread
    private let label: String

    public init(label: String) {
        self.label = label
        let runLoopBox = RunLoopBox()
        let barrier = DispatchSemaphore(value: 0)

        let thread = Thread {
            runLoopBox.runLoop = CFRunLoopGetCurrent()
            Thread.current.name = label

            // CFRunLoop exits immediately if it has no sources. Add a no-op source so it stays alive.
            var ctx = CFRunLoopSourceContext()
            ctx.version = 0
            ctx.perform = { _ in /* no-op */ }
            let source = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &ctx)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)

            barrier.signal()

            // Run forever.
            CFRunLoopRun()
        }
        thread.qualityOfService = .userInteractive
        thread.stackSize = 1024 * 1024 // 1 MB; libgphoto2 deep call stacks need headroom
        thread.start()

        barrier.wait()
        self.thread = thread
        guard let captured = runLoopBox.runLoop else {
            fatalError("PinnedThreadExecutor: failed to capture run loop")
        }
        self.runLoop = captured
    }

    public func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        let executor = self.asUnownedSerialExecutor()
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            unowned.runSynchronously(on: executor)
        }
        CFRunLoopWakeUp(runLoop)
    }

    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    /// Returns the Mach thread ID of the pinned thread. Used to verify every
    /// `gp_camera_*` call observes the same `pthread_self()` across a session.
    public func currentPinnedThreadID() async -> UInt64 {
        await withCheckedContinuation { (cont: CheckedContinuation<UInt64, Never>) in
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                cont.resume(returning: UInt64(pthread_mach_thread_np(pthread_self())))
            }
            CFRunLoopWakeUp(runLoop)
        }
    }
}

private final class RunLoopBox: @unchecked Sendable {
    var runLoop: CFRunLoop?
}
