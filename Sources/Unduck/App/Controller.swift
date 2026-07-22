import CoreAudio
import Foundation
import ServiceManagement
import SwiftUI

/// Owns the engage/restore lifecycle: detect a call, take over the audio, split the
/// 30 dB makeup between hardware volume and digital gain, and put everything back
/// when the call ends.
@MainActor
final class Controller: ObservableObject {
    /// Measured on this hardware, 2026-07-22, twice, on both RMS and peak.
    /// Re-measured per device by `Calibration` once that exists; until then this is
    /// the observed constant rather than the ~20 dB the public reports claim.
    static let measuredDuckDB: Float = 30.0

    /// How much of the duck to undo. Starts below the measured 30 dB on purpose:
    /// full compensation is only correct while the duck is actually applied, and
    /// any gap between the call ending and Unduck restoring is heard at this much
    /// extra gain. Verified on a real call 2026-07-22: engage and restore both fire
    /// promptly, so this now defaults to the full measured duck.
    @Published var compensationDB: Float = 30

    @Published var isOnCall = false
    @Published var isEngaged = false
    @Published var enabled = true
    @Published var status = "Waiting for a call"

    @Published var callLevel: Float = 1.0 { didSet { pushLevels() } }
    @Published var mediaLevel: Float = 1.0 { didSet { pushLevels() } }
    @Published var masterLevel: Float = 1.0 { didSet { pushLevels() } }

    private let detector = CallDetector()
    private let engine = MixEngine()
    private let volumeGuard = VolumeGuard()
    private let resumer = MediaResumer()

    @Published var permission = AudioCapturePermission.state

    /// Start Unduck automatically at login.
    ///
    /// Registered through SMAppService rather than a LaunchAgent plist: the modern
    /// API keeps the login item tied to the app bundle, so moving or deleting the
    /// app cleans it up instead of leaving an orphaned agent that fails silently
    /// every boot.
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                Log.write("launch at login -> \(launchAtLogin)")
            } catch {
                Log.write("launch at login failed: \(error)")
                status = "Could not change login item: \(error.localizedDescription)"
            }
        }
    }

    /// True when running from /Applications. Permissions are keyed to the signature,
    /// but a login item pointing into a build directory breaks the moment that
    /// directory is cleaned or moved.
    var isInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    /// Un-pause media that the call interrupted. On by default: a mixer that
    /// rebalances silence is useless, and the resumer only ever touches apps it
    /// saw playing immediately before the call.
    @Published var autoResume = true

    /// End-to-end test of the takeover path without needing a live call: taps and
    /// mutes every source and re-renders it at unity, with no makeup gain and no
    /// change to the hardware volume. If audio keeps playing and the faders move it,
    /// the whole chain works; the only untested piece is the 30 dB compensation,
    /// which cannot exist without a call to duck it.
    var testModeAvailable: Bool { true }

    init() {
        // Before anything else touches audio: if a previous run died while the
        // volume was raised, give it back.
        volumeGuard.recoverFromCrash()

        Log.write("launch — audio-capture permission: \(AudioCapturePermission.state)")
        AudioCapturePermission.request { [weak self] state in
            guard let self else { return }
            Log.write("after request — audio-capture permission: \(state)")
            self.permission = state
            if !state.isUsable { self.status = state.explanation }
        }

        resumer.mediaPeakDB = { [weak self] in self?.engine.lastMediaPeakDB ?? -.infinity }

        // Safety path: runs on the detector's queue the moment the call ends, with
        // no dependency on the main thread or on the UI. `disengage()` still runs
        // afterwards for teardown and is idempotent — restoring twice is a no-op.
        detector.onCallEndedImmediate = { [engine, volumeGuard] in
            engine.silenceOutput()
            volumeGuard.restore()
        }

        detector.onChange = { [weak self] onCall in
            guard let self else { return }
            self.isOnCall = onCall
            if onCall { self.resumer.snapshot() }
            guard self.enabled else { return }
            onCall ? self.engage() : self.disengage()
        }
        detector.start()
    }

    func engage(compensate: Bool = true) {
        guard !isEngaged else { return }
        guard permission.isUsable else {
            status = permission.explanation
            return
        }
        do {
            let device = try defaultOutputDevice()

            // Split the makeup. Hardware volume first, because it is clean gain
            // applied after the duck; digital makes up only what the hardware
            // cannot reach, and the limiter catches the rest.
            //
            // Compensation is applied ONLY when a call is genuinely up. Engaging
            // with makeup and no duck to cancel would hand the user 30 dB of extra
            // level, which is the loudest possible way to be wrong.
            var hardwareDB: Float = 0
            if compensate, let currentDB = deviceVolumeDecibels(device) {
                let targetDB = min(0, currentDB + compensationDB)
                hardwareDB = targetDB - currentDB
                if let scalar = deviceScalar(for: targetDB, on: device) {
                    try volumeGuard.engage(device: device, targetScalar: scalar)
                }
            }
            let digitalDB = compensate ? compensationDB - hardwareDB : 0

            try engine.start(makeupDB: digitalDB)
            pushLevels()
            isEngaged = true
            status = String(format: "Engaged — %.0f dB hardware + %.0f dB digital", hardwareDB, digitalDB)
            Log.write("engaged (compensate=\(compensate)) hardware=\(hardwareDB)dB digital=\(digitalDB)dB")
            if compensate && autoResume { resumer.begin() }
        } catch {
            // Never leave the machine half-taken-over — and never in the loud
            // direction. If the volume was already raised before the failure,
            // dropping it must precede un-muting the sources.
            engine.silenceOutput()
            volumeGuard.restore()
            engine.stop()
            isEngaged = false
            status = "Failed: \(error)"
            Log.write("engage FAILED: \(error)")
        }
    }

    func disengage() {
        guard isEngaged else { return }
        Log.write("disengaging")
        // Our own output first, then volume, then the engine. Each step is ordered
        // so the machine is never loud: silence what we render while the volume is
        // still high, drop the volume, and only then un-mute the sources.
        resumer.cancel()
        engine.silenceOutput()
        // Volume second, engine last. The duck lifts the instant the call ends, so
        // every millisecond spent with the hardware still boosted is a millisecond
        // of everything playing far too loud. Stopping the engine also un-mutes
        // every source, so doing that first would uncork full-level audio into a
        // raised volume.
        volumeGuard.restore()
        engine.stop()
        isEngaged = false
        status = "Waiting for a call"
    }

    /// Panic button, and the handler for every termination path.
    func restoreEverything() {
        engine.silenceOutput()
        volumeGuard.restore()
        engine.stop()
        isEngaged = false
        status = "Restored"
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on {
            disengage()
            status = "Disabled"
        } else if isOnCall {
            engage()
        } else {
            status = "Waiting for a call"
        }
    }

    func requestResumePermissions() {
        resumer.requestAllPermissions()
        status = "Approve the permission dialogs, then try a call"
    }

    private func pushLevels() {
        engine.levels = .init(call: callLevel, media: mediaLevel, master: masterLevel)
    }
}
