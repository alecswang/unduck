import AppKit
import CoreAudio
import Foundation

/// Un-pauses media that macOS stopped when the call started.
///
/// Starting a call fires a system-wide audio interruption and media apps stop
/// themselves. Unduck can rebalance audio but it cannot rebalance silence, so it
/// has to ask them to resume.
///
/// **Media key injection only.** Two other approaches were tried and abandoned:
///
///  * **MediaRemote** is the intended API, but macOS 15.4 added entitlement checks
///    to `mediaremoted` and unentitled clients are refused outright.
///  * **AppleScript** looked ideal — `player state` gives a precise per-app answer
///    for Spotify and Music, immune to the mixed-bus problem below. It never worked
///    once. The consent dialog never appeared, and worse,
///    `AEDeterminePermissionToAutomateTarget` blocks the calling thread indefinitely
///    *even with `askUserIfNeeded: false`*. Called from the resumer's timer, that
///    froze the main thread mid-call, which prevented `disengage()` from running,
///    which left the hardware volume 30 dB high after hangup. A cosmetic feature
///    took out a safety-critical one. Not worth reviving without a consent query
///    that cannot block.
///
/// The media key is a blind toggle with no readable state, so it only fires after
/// sustained silence on the media bus, where there is no playback for it to stop by
/// mistake. It reaches whatever owns Now Playing, covering Spotify, browsers and
/// everything else through one mechanism and one permission.
///
/// Everything here runs on a private queue. Nothing in this file may touch the main
/// thread: this is a convenience feature sharing a process with a safety-critical
/// volume restore, and it must never be able to stall it.
final class MediaResumer {
    /// Supplies the current media-bus peak in dBFS.
    var mediaPeakDB: () -> Double = { -.infinity }

    /// Below this the media bus counts as silent. Well under anything audible, but
    /// above the numeric floor so a quiet passage does not trip it.
    private static let silenceThresholdDB = -70.0

    /// Consecutive silent ticks before acting. The interruption is not instant, and
    /// firing a toggle into a momentary gap would pause something still playing.
    private static let silentTicksBeforeAct = 2

    private let queue = DispatchQueue(label: "unduck.resumer")
    private var timer: DispatchSourceTimer?
    private var hadMediaBeforeCall = false
    private var silentTicks = 0
    private var ticksSinceKey = 99
    private var ticks = 0

    /// Record whether anything was playing. Call the moment a call is detected,
    /// before the interruption has had time to stop anything.
    ///
    /// Only apps producing audio *before* the call are ever resumed — Unduck must
    /// not override a pause the user made themselves.
    func snapshot() {
        let playing = ((try? allAudioProcesses()) ?? [])
            .filter { $0.runningOutput && $0.pid != getpid() }
            .compactMap(\.bundleID)
            .filter { $0 != "com.apple.avconferenced" && $0 != "com.apple.CoreSpeech" }
        queue.async {
            self.hadMediaBeforeCall = !playing.isEmpty
            self.silentTicks = 0
            self.ticksSinceKey = 99
            self.ticks = 0
        }
        Log.write("resumer: playing before call — \(playing.isEmpty ? "nothing" : playing.joined(separator: ", "))")
    }

    /// Watch for the whole call.
    ///
    /// An earlier version stopped at the first sign of audio and so missed every app
    /// that pauses late — Spotify stops well after the call connects, by which point
    /// the resumer had already declared success and gone home.
    func begin() {
        queue.async {
            guard self.hadMediaBeforeCall else {
                Log.write("resumer: nothing was playing before the call — nothing to resume")
                return
            }
            Log.write("resumer: watching for the duration of the call")
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    func cancel() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.hadMediaBeforeCall = false
            self.silentTicks = 0
        }
    }

    private func tick() {
        ticks += 1
        ticksSinceKey += 1

        let peak = mediaPeakDB()
        let silent = !(peak > Self.silenceThresholdDB)
        silentTicks = silent ? silentTicks + 1 : 0

        if silent || ticks % 10 == 1 {
            Log.write(String(format: "resumer: t%d — media peak %.1f dBFS (%@), silent %d, accessibility=%@",
                             ticks, peak, silent ? "silent" : "playing", silentTicks,
                             AXIsProcessTrusted() ? "true" : "false"))
        }

        // Rate-limited: a media key press takes a moment to take effect, and firing
        // again before the level catches up would toggle it straight back off.
        guard silentTicks >= Self.silentTicksBeforeAct, ticksSinceKey >= 3 else { return }
        ticksSinceKey = 0
        sendPlayKey()
    }

    private func sendPlayKey() {
        guard AXIsProcessTrusted() else {
            Log.write("resumer: media key needs Accessibility — grant it in System Settings")
            return
        }
        postMediaKey(down: true)
        postMediaKey(down: false)
        Log.write("resumer: sent play/pause media key")
    }

    private static let playKeyCode: Int32 = 16   // NX_KEYTYPE_PLAY

    private func postMediaKey(down: Bool) {
        let flags = down ? 0xa00 : 0xb00
        let data1 = Int((Self.playKeyCode << 16) | Int32(flags))
        guard let event = NSEvent.otherEvent(with: .systemDefined,
                                             location: .zero,
                                             modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                                             timestamp: 0,
                                             windowNumber: 0,
                                             context: nil,
                                             subtype: 8,
                                             data1: data1,
                                             data2: -1) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }

    /// Accessibility is the only permission this needs. It cannot be granted by a
    /// dialog — macOS only lets the user toggle it manually — so this just points
    /// them at the right pane.
    func requestAllPermissions() {
        Log.write("resumer: accessibility currently \(AXIsProcessTrusted())")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
