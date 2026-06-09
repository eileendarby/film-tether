import Foundation

@globalActor
public actor CameraActor {
    public static let shared = CameraActor()

    private static let executor = PinnedThreadExecutor(label: "co.wonders.filmtether.camera-thread")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        Self.executor.asUnownedSerialExecutor()
    }

    /// Returns the Mach thread ID of the pinned camera thread.
    /// Thread-affinity invariant: this value must be stable across every `gp_camera_*` call in a session.
    public static func pthreadID() async -> UInt64 {
        await executor.currentPinnedThreadID()
    }
}
