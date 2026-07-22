import Foundation

/// Audio-capture permission.
///
/// There is no public API for this. Creating a process tap does **not** trigger a
/// prompt — it succeeds, delivers correctly-sized buffers, and fills every one of
/// them with zeros. Silence and denial are indistinguishable from the outside, so
/// the grant has to be requested explicitly and its state surfaced in the UI.
///
/// Hence the private TCC calls below. `AVCaptureDevice.requestAccess(for: .audio)`
/// is not a substitute: it covers the microphone, a different service from
/// `kTCCServiceAudioCapture`. This is why Unduck ships outside the App Store.
enum AudioCapturePermission {
    enum State: Int {
        case granted = 0
        case denied = 1
        case undetermined = 2
        case unknown = -1

        var isUsable: Bool { self == .granted }

        var explanation: String {
            switch self {
            case .granted: return "Audio capture allowed"
            case .denied: return "Audio capture denied — enable Unduck in System Settings > Privacy & Security"
            case .undetermined: return "Audio capture not yet allowed"
            case .unknown: return "Could not read audio capture permission"
            }
        }
    }

    private static let service = "kTCCServiceAudioCapture"

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)

    static var state: State {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unknown }
        let preflight = unsafeBitCast(symbol, to: PreflightFn.self)
        return State(rawValue: Int(preflight(service as CFString, nil))) ?? .unknown
    }

    /// Asks once. A denial is sticky — macOS will not prompt again — so the caller
    /// must fall back to pointing the user at System Settings.
    static func request(_ completion: @escaping (State) -> Void) {
        guard state != .granted else { return completion(.granted) }
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else { return completion(.unknown) }
        let request = unsafeBitCast(symbol, to: RequestFn.self)
        request(service as CFString, nil) { _ in
            DispatchQueue.main.async { completion(state) }
        }
    }
}
