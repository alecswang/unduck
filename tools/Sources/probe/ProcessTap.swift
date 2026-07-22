import AudioToolbox
import CoreAudio
import Darwin
import Foundation

/// Wraps a Core Audio process tap (macOS 14.4+) plus the private aggregate device
/// needed to actually pull samples out of it.
final class ProcessTap {
    enum Target {
        case processes([AudioObjectID])
        case allExcept([AudioObjectID])
    }

    private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private(set) var format = AudioStreamBasicDescription()
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false

    let mute: Bool
    let label: String
    private let ioQueue: DispatchQueue

    init(label: String, target: Target, mute: Bool) throws {
        self.label = label
        self.mute = mute
        self.ioQueue = DispatchQueue(label: "unduck.tap.\(label)", qos: .userInitiated)

        let description: CATapDescription
        switch target {
        case .processes(let ids):
            description = CATapDescription(stereoMixdownOfProcesses: ids)
        case .allExcept(let ids):
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: ids)
        }
        description.name = "Unduck-\(label)"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = mute ? .muted : .unmuted

        try check("AudioHardwareCreateProcessTap", AudioHardwareCreateProcessTap(description, &tapID))
        guard tapID != kAudioObjectUnknown else {
            throw CAError.status("AudioHardwareCreateProcessTap(unknown id)", kAudioHardwareBadObjectError)
        }

        // The tap's stream format tells us what the aggregate will hand us.
        var addr = address(kAudioTapPropertyFormat)
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("kAudioTapPropertyFormat",
                  AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &format))

        let outputDevice = try defaultOutputDevice()
        guard let outputUID = deviceUID(outputDevice) else {
            throw CAError.status("deviceUID", kAudioHardwareUnknownPropertyError)
        }

        let aggregateUID = UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Unduck Tap \(label)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check("AudioHardwareCreateAggregateDevice",
                  AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID))
    }

    /// Installs an IO proc. The block receives interleaved float samples for the tap stream.
    ///
    /// The IO block gets its own serial queue on purpose. Passing nil here dispatches
    /// to the main queue, so anything that blocks main (a bare `Thread.sleep` in a
    /// test, say) silently stops sample delivery and the tap looks dead when it is
    /// merely starved — that cost us a bogus "FaceTime delivers 0 samples" reading.
    func start(_ onSamples: @escaping (UnsafePointer<Float>, Int, Int) -> Void) throws {
        let channels = Int(format.mChannelsPerFrame)
        var procID: AudioDeviceIOProcID?
        try check("AudioDeviceCreateIOProcIDWithBlock",
                  AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inputData, _, _, _ in
                      let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                      guard let first = buffers.first, let raw = first.mData else { return }
                      let bytes = Int(first.mDataByteSize)
                      let frames = bytes / MemoryLayout<Float>.size / max(1, Int(first.mNumberChannels))
                      raw.withMemoryRebound(to: Float.self, capacity: bytes / MemoryLayout<Float>.size) { ptr in
                          onSamples(ptr, frames, Int(first.mNumberChannels) == 0 ? channels : Int(first.mNumberChannels))
                      }
                  })
        ioProcID = procID
        try check("AudioDeviceStart", AudioDeviceStart(aggregateID, procID))
        started = true
    }

    func stop() {
        if started, let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        started = false
        ioProcID = nil
    }

    func invalidate() {
        stop()
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit { invalidate() }
}

/// Rolling RMS / peak meter in dBFS.
final class Meter {
    private var sumSquares: Double = 0
    private var count: Int = 0
    private var peak: Float = 0
    private let lock = NSLock()

    func add(_ samples: UnsafePointer<Float>, frames: Int, channels: Int) {
        var s: Double = 0
        var p: Float = 0
        let total = frames * channels
        for i in 0..<total {
            let v = samples[i]
            s += Double(v) * Double(v)
            let a = abs(v)
            if a > p { p = a }
        }
        lock.lock()
        sumSquares += s
        count += total
        if p > peak { peak = p }
        lock.unlock()
    }

    /// Returns (rmsDBFS, peakDBFS, sampleCount) and resets.
    func drain() -> (rms: Double, peak: Double, samples: Int) {
        lock.lock()
        let s = sumSquares, c = count, p = peak
        sumSquares = 0; count = 0; peak = 0
        lock.unlock()
        guard c > 0 else { return (-Double.infinity, -Double.infinity, 0) }
        let rms = (s / Double(c)).squareRoot()
        return (dbfs(rms), dbfs(Double(p)), c)
    }
}

func dbfs(_ linear: Double) -> Double {
    linear <= 0 ? -Double.infinity : 20 * log10(linear)
}

func fmt(_ db: Double) -> String {
    db.isFinite ? String(format: "%7.2f", db) : "   -inf"
}
