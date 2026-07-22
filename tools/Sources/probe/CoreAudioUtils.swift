import CoreAudio
import Foundation

// Thin wrappers over the AudioObject property API. Everything here is public API;
// nothing private is used, so the shipping app can lift these verbatim.

enum CAError: Error, CustomStringConvertible {
    case status(String, OSStatus)

    var description: String {
        switch self {
        case .status(let what, let code):
            return "\(what) failed: OSStatus \(code) (\(fourCC(code)))"
        }
    }
}

func fourCC(_ code: OSStatus) -> String {
    let n = UInt32(bitPattern: code)
    let bytes = [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
    let s = String(bytes: bytes, encoding: .ascii) ?? "?"
    return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " } ? "'\(s)'" : "?"
}

@discardableResult
func check(_ what: String, _ status: OSStatus) throws -> OSStatus {
    guard status == noErr else { throw CAError.status(what, status) }
    return status
}

func address(_ selector: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func propertyDataSize(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress,
                      qualifierSize: UInt32 = 0, qualifier: UnsafeRawPointer? = nil) throws -> UInt32 {
    var size: UInt32 = 0
    var a = addr
    try check("AudioObjectGetPropertyDataSize", AudioObjectGetPropertyDataSize(object, &a, qualifierSize, qualifier, &size))
    return size
}

/// Reads a fixed-size property. `T` must be a trivial type (the Core Audio
/// property values used here are all integers, floats and object IDs) — taking the
/// address of a generic value directly makes the compiler warn, correctly, that a
/// `T` containing object references would be handed to C as raw bytes.
func readProperty<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, default def: T) -> T {
    var a = addr
    var size = UInt32(MemoryLayout<T>.size)
    let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size,
                                               alignment: MemoryLayout<T>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, raw) == noErr,
          size == UInt32(MemoryLayout<T>.size) else { return def }
    return raw.load(as: T.self)
}

func readArrayProperty<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, of type: T.Type,
                          qualifierSize: UInt32 = 0, qualifier: UnsafeRawPointer? = nil) throws -> [T] {
    let size = try propertyDataSize(object, addr, qualifierSize: qualifierSize, qualifier: qualifier)
    let count = Int(size) / MemoryLayout<T>.size
    guard count > 0 else { return [] }
    var a = addr
    var mutableSize = size
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { raw.deallocate() }
    try check("AudioObjectGetPropertyData(array)",
              AudioObjectGetPropertyData(object, &a, qualifierSize, qualifier, &mutableSize, raw))
    let returned = Int(mutableSize) / MemoryLayout<T>.size
    return (0..<min(count, returned)).map { raw.load(fromByteOffset: $0 * MemoryLayout<T>.size, as: T.self) }
}

func readStringProperty(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
    var a = addr
    var value: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
    }
    guard status == noErr else { return nil }
    return value as String?
}

// MARK: - Process objects (macOS 14.0+)

struct AudioProcess {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String?
    var runningInput: Bool
    var runningOutput: Bool

    var name: String {
        if let bundleID, !bundleID.isEmpty { return bundleID }
        if let app = NSRunningApplicationName(for: pid) { return app }
        return "pid \(pid)"
    }
}

func NSRunningApplicationName(for pid: pid_t) -> String? {
    // Avoid AppKit in a CLI: read the executable path from the process table instead.
    var buffer = [CChar](repeating: 0, count: 4096)
    let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard n > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
}

func allAudioProcesses() throws -> [AudioProcess] {
    let ids = try readArrayProperty(AudioObjectID(kAudioObjectSystemObject),
                                    address(kAudioHardwarePropertyProcessObjectList),
                                    of: AudioObjectID.self)
    return ids.map { id in
        AudioProcess(
            objectID: id,
            pid: readProperty(id, address(kAudioProcessPropertyPID), default: pid_t(-1)),
            bundleID: readStringProperty(id, address(kAudioProcessPropertyBundleID)),
            runningInput: readProperty(id, address(kAudioProcessPropertyIsRunningInput), default: UInt32(0)) != 0,
            runningOutput: readProperty(id, address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0)) != 0
        )
    }
}

func processObject(forPID pid: pid_t) throws -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var inPID = pid
    var objectID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check("TranslatePIDToProcessObject",
              AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         UInt32(MemoryLayout<pid_t>.size), &inPID, &size, &objectID))
    guard objectID != kAudioObjectUnknown else {
        throw CAError.status("TranslatePIDToProcessObject(unknown)", kAudioHardwareBadObjectError)
    }
    return objectID
}

func pids(matching needle: String) -> [pid_t] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    task.arguments = ["-f", needle]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do { try task.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
}

// MARK: - Devices

func defaultOutputDevice() throws -> AudioObjectID {
    var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try check("DefaultOutputDevice",
              AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device))
    return device
}

func deviceUID(_ device: AudioObjectID) -> String? {
    readStringProperty(device, address(kAudioDevicePropertyDeviceUID))
}

func deviceName(_ device: AudioObjectID) -> String? {
    readStringProperty(device, address(kAudioObjectPropertyName))
}

/// Number of output channels, summed across all streams in the output scope.
func deviceOutputChannelCount(_ device: AudioObjectID) -> Int {
    let addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
    guard let size = try? propertyDataSize(device, addr), size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    var a = addr
    var mutableSize = size
    guard AudioObjectGetPropertyData(device, &a, 0, nil, &mutableSize, raw) == noErr else { return 0 }
    let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func deviceVolumeScalar(_ device: AudioObjectID) -> Float32? {
    var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
    if AudioObjectHasProperty(device, &addr) {
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr { return v }
    }
    // Some devices only expose per-channel volume.
    for channel in UInt32(1)...UInt32(2) {
        var chAddr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, channel)
        if AudioObjectHasProperty(device, &chAddr) {
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &chAddr, 0, nil, &size, &v) == noErr { return v }
        }
    }
    return nil
}

func setDeviceVolumeScalar(_ device: AudioObjectID, _ value: Float32) throws {
    let clamped = max(0, min(1, value))
    var addr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput)
    if AudioObjectHasProperty(device, &addr) {
        var v = clamped
        try check("SetVolumeScalar(main)",
                  AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v))
        return
    }
    var didSet = false
    for channel in UInt32(1)...UInt32(2) {
        var chAddr = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, channel)
        if AudioObjectHasProperty(device, &chAddr) {
            var v = clamped
            try check("SetVolumeScalar(ch\(channel))",
                      AudioObjectSetPropertyData(device, &chAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v))
            didSet = true
        }
    }
    guard didSet else { throw CAError.status("SetVolumeScalar(no settable volume)", kAudioHardwareUnknownPropertyError) }
}

func deviceVolumeDecibels(_ device: AudioObjectID) -> Float32? {
    var addr = address(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput)
    if AudioObjectHasProperty(device, &addr) {
        var v: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr { return v }
    }
    for channel in UInt32(1)...UInt32(2) {
        var chAddr = address(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeOutput, channel)
        if AudioObjectHasProperty(device, &chAddr) {
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &chAddr, 0, nil, &size, &v) == noErr { return v }
        }
    }
    return nil
}
