import Foundation

// Diagnostic only — this is private API and does not ship in the app.
//
// There is no public way to ask "do I have the audio-capture grant?", and a denied
// tap is indistinguishable from real silence: samples still flow, they are just
// all zero. TCCAccessPreflight tells us which of the three states we are in, which
// is the difference between "prompt the user" and "the user must fix it in
// System Settings because macOS will never ask again".
enum TCCState: Int, CustomStringConvertible {
    case granted = 0
    case denied = 1
    case undetermined = 2

    var description: String {
        switch self {
        case .granted: return "GRANTED"
        case .denied: return "DENIED (sticky — macOS will not re-prompt)"
        case .undetermined: return "UNDETERMINED (a prompt is still possible)"
        }
    }
}

private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
// The completion block outlives the call — tccd answers asynchronously, and
// without @escaping the runtime traps with "closure argument passed as @noescape
// to Objective-C has escaped".
private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

private func tccHandle() -> UnsafeMutableRawPointer? {
    dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)
}

func tccPreflight(_ service: String) -> TCCState? {
    guard let handle = tccHandle(), let sym = dlsym(handle, "TCCAccessPreflight") else { return nil }
    let fn = unsafeBitCast(sym, to: PreflightFn.self)
    return TCCState(rawValue: Int(fn(service as CFString, nil)))
}

func tccRequest(_ service: String, timeout: TimeInterval = 30) -> Bool? {
    guard let handle = tccHandle(), let sym = dlsym(handle, "TCCAccessRequest") else { return nil }
    let fn = unsafeBitCast(sym, to: RequestFn.self)
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    fn(service as CFString, nil) { result in
        granted = result
        semaphore.signal()
    }
    return semaphore.wait(timeout: .now() + timeout) == .success ? granted : nil
}

let audioCaptureService = "kTCCServiceAudioCapture"
let microphoneService = "kTCCServiceMicrophone"
