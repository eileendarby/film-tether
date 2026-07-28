// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "FilmTether",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FilmTether", targets: ["App"]),
        .library(name: "Camera", targets: ["Camera"]),
        .library(name: "Hotkey", targets: ["Hotkey"]),
        .library(name: "Scan", targets: ["Scan"]),
    ],
    targets: [
        .systemLibrary(
            name: "CGPhoto2",
            path: "Sources/CGPhoto2",
            pkgConfig: "libgphoto2",
            providers: [
                .brew(["libgphoto2"]),
            ]
        ),
        .target(
            name: "UsbReset",
            path: "Sources/UsbReset",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "Camera",
            dependencies: ["CGPhoto2", "UsbReset"],
            path: "Sources/Camera",
            linkerSettings: [
                // Belt-and-suspenders for `ld`; pkg-config already provides -L for libgphoto2,
                // but these don't hurt and they help if pkg-config ever fails.
                // Note: unsafeFlags accepts absolute paths; .headerSearchPath does NOT.
                .unsafeFlags(["-L/opt/homebrew/lib", "-L/usr/local/lib"]),
            ]
        ),
        .target(
            name: "Hotkey",
            dependencies: [],
            path: "Sources/Hotkey"
        ),
        // Film-scanning domain model: preview rotation, crop geometry, film
        // negative sizes, and (later) the sidecar / REST payloads. Deliberately
        // free of libgphoto2 and SwiftUI so it stays unit-testable — AppModel is
        // @MainActor and window-server-bound, so none of this logic can be
        // tested if it lives there.
        .target(
            name: "Scan",
            dependencies: [],
            path: "Sources/Scan"
        ),
        .executableTarget(
            name: "App",
            dependencies: ["Camera", "Hotkey", "Scan"],
            path: "Sources/App",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
        // Headless CLI for running the Camera stack from a terminal. Used to
        // exercise capture, live view, manual focus, metering, and EXIF
        // verification without launching the SwiftUI app. Crucial for
        // headless testing over SSH. The GUI app needs
        // the OS window server, this doesn't.
        .executableTarget(
            name: "FilmTetherDebug",
            dependencies: ["Camera"],
            path: "Sources/Debug",
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"]),
            ]
        ),
        .testTarget(
            name: "CameraTests",
            dependencies: ["Camera"],
            path: "Tests/CameraTests"
        ),
        .testTarget(
            name: "ScanTests",
            dependencies: ["Scan"],
            path: "Tests/ScanTests"
        ),
    ]
)
