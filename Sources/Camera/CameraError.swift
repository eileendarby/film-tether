import Foundation
import CGPhoto2

public enum CameraError: Error, LocalizedError {
    case libGPhoto(code: Int32, message: String)
    case cameraNotFound
    case usbClaimDenied(underlying: Int32)
    case propertyReadOnly(name: String)
    case propertyNotFound(name: String)
    case widgetTypeMismatch(expected: String, got: String)
    case liveViewNotActive
    case connectionLost
    case firmwareTooOld(detected: String)
    case unsupportedMode(current: String)
    case captureFailed(reason: String)
    case sessionAlreadyOpen
    case sessionNotOpen

    public var errorDescription: String? {
        switch self {
        case .libGPhoto(let code, let message):
            return "libgphoto2 error \(code): \(message)"
        case .cameraNotFound:
            return "No compatible camera detected on USB. Plug in the camera and turn it on."
        case .usbClaimDenied(let underlying):
            return "macOS is holding the camera's USB interface (gphoto2 error \(underlying)). " +
                   "Quit Image Capture and any photo apps, then try again."
        case .propertyReadOnly(let name):
            return "The property '\(name)' is not settable in the current camera mode."
        case .propertyNotFound(let name):
            return "The camera does not expose a property named '\(name)'."
        case .widgetTypeMismatch(let expected, let got):
            return "Widget type mismatch: expected \(expected), got \(got)."
        case .liveViewNotActive:
            return "Live view is not active."
        case .connectionLost:
            return "Lost connection to the camera."
        case .firmwareTooOld(let detected):
            return "Detected camera firmware \(detected). Update to the latest supported version in-camera before tethering."
        case .unsupportedMode(let current):
            return "Operation not supported in current mode '\(current)'."
        case .captureFailed(let reason):
            return "Capture failed: \(reason)."
        case .sessionAlreadyOpen:
            return "Camera session is already open."
        case .sessionNotOpen:
            return "Camera session is not open."
        }
    }

    /// Convert a libgphoto2 result code (`Int32`) to a `CameraError`, or `nil` if `GP_OK`.
    public static func from(rc: Int32) -> CameraError? {
        if rc == GP_OK { return nil }
        // GP_ERROR_IO_USB_CLAIM is -53
        if rc == -53 { return .usbClaimDenied(underlying: rc) }
        let message: String
        if let cString = gp_result_as_string(rc) {
            message = String(cString: cString)
        } else {
            message = "unknown libgphoto2 error"
        }
        return .libGPhoto(code: rc, message: message)
    }

    /// Throws if `rc != GP_OK`.
    public static func check(_ rc: Int32) throws {
        if let err = from(rc: rc) { throw err }
    }
}
