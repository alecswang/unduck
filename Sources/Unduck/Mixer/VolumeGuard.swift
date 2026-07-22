import CoreAudio
import Foundation

/// Owns every change Unduck makes to the output device's hardware volume, and
/// guarantees the user gets their level back.
///
/// Compensating the 30 dB duck means raising the hardware volume a long way. If
/// Unduck dies while raised — crash, force quit, power loss — the next sound the
/// user hears is 30 dB louder than they asked for. That is the worst thing this app
/// can do, so the restore path is written first and does not depend on graceful
/// shutdown: the pre-engage level is persisted to disk *before* the volume moves,
/// and reclaimed on the next launch.
final class VolumeGuard {
    private let stateURL: URL
    private var originalScalar: Float32?
    private var device: AudioObjectID?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Unduck", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        stateURL = support.appendingPathComponent("pending-volume-restore.json")
    }

    private struct Pending: Codable {
        var deviceUID: String
        var scalar: Float32
    }

    /// Call once at launch, before anything else touches audio.
    func recoverFromCrash() {
        guard let data = try? Data(contentsOf: stateURL),
              let pending = try? JSONDecoder().decode(Pending.self, from: data) else { return }
        defer { try? FileManager.default.removeItem(at: stateURL) }

        guard let devices = try? readArrayProperty(AudioObjectID(kAudioObjectSystemObject),
                                                   address(kAudioHardwarePropertyDevices),
                                                   of: AudioObjectID.self) else { return }
        guard let match = devices.first(where: { deviceUID($0) == pending.deviceUID }) else { return }
        try? setDeviceVolumeScalar(match, pending.scalar)
        NSLog("Unduck: restored volume %.3f on %@ after unclean shutdown", pending.scalar, pending.deviceUID)
    }

    /// Raise the device volume, remembering where it was. Idempotent.
    func engage(device: AudioObjectID, targetScalar: Float32) throws {
        if originalScalar == nil {
            guard let current = deviceVolumeScalar(device) else {
                throw CAError.status("device has no settable volume", kAudioHardwareUnknownPropertyError)
            }
            originalScalar = current
            self.device = device
            if let uid = deviceUID(device) {
                let data = try JSONEncoder().encode(Pending(deviceUID: uid, scalar: current))
                try? data.write(to: stateURL, options: .atomic)
            }
        }
        try setDeviceVolumeScalar(device, targetScalar)
        Log.write("volume \(originalScalar ?? -1) -> \(targetScalar) (now \(deviceVolumeScalar(device) ?? -1))")
    }

    /// Put it back exactly where the user had it.
    func restore() {
        defer {
            originalScalar = nil
            device = nil
            try? FileManager.default.removeItem(at: stateURL)
        }
        guard let device, let originalScalar else { return }
        try? setDeviceVolumeScalar(device, originalScalar)
        Log.write("volume restored to \(originalScalar) (now \(deviceVolumeScalar(device) ?? -1))")
    }

    var isEngaged: Bool { originalScalar != nil }
}
