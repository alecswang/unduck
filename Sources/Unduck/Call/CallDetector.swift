import CoreAudio
import Foundation

/// Detects an active FaceTime call.
///
/// Watches `avconferenced`, NOT FaceTime.app. Measured on 2026-07-22: FaceTime.app
/// never opens audio input during a call — the daemon owns the mic, and the 30 dB
/// duck engages the instant `avconferenced` starts running input. Watching the app
/// gives a detector that reads "no call" for the entire call.
///
/// `CoreSpeech` also holds input more or less permanently (always-on Siri), so
/// "somebody is using the mic" is not a usable signal either. It has to be this
/// specific daemon.
final class CallDetector {
    static let daemonName = "avconferenced"

    private(set) var isOnCall = false
    private var daemonObject: AudioObjectID?
    private var listener: AudioObjectPropertyListenerBlock?
    private let queue = DispatchQueue(label: "unduck.calldetector")
    private var poll: DispatchSourceTimer?

    var onChange: ((Bool) -> Void)?

    /// Fired **synchronously on the detector's own queue** the instant a call ends,
    /// before anything is hopped to the main thread.
    ///
    /// Restoring the hardware volume is safety-critical and must not depend on the
    /// main thread being responsive. It once did, and when an unrelated feature
    /// blocked main mid-call, the volume stayed 30 dB high after hangup. Anything
    /// that protects the user's hearing runs here; UI updates can wait their turn.
    var onCallEndedImmediate: (() -> Void)?

    func start() {
        queue.async { [weak self] in
            self?.attach()
            self?.startPolling()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.detach()
            self?.poll?.cancel()
            self?.poll = nil
        }
    }

    // MARK: - Wiring

    private func attach() {
        detach()
        guard let pid = pids(matching: Self.daemonName).first,
              let object = try? processObject(forPID: pid) else { return }
        daemonObject = object

        var addr = address(kAudioProcessPropertyIsRunningInput)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.queue.async { self?.evaluate() }
        }
        if AudioObjectAddPropertyListenerBlock(object, &addr, queue, block) == noErr {
            listener = block
        }
        evaluate()
    }

    private func detach() {
        if let object = daemonObject, let listener {
            var addr = address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(object, &addr, queue, listener)
        }
        listener = nil
        daemonObject = nil
    }

    /// The daemon is not guaranteed to be alive, and its process object is not stable
    /// across relaunches, so a poll re-attaches the listener and catches anything the
    /// notification missed.
    ///
    /// The interval is 50 ms, not something leisurely, because this is a **safety**
    /// timer, not a UI timer. Compensation leaves the hardware volume ~30 dB high,
    /// and that is only correct while the duck is applied. The duck lifts the
    /// instant the call ends, so every millisecond before Unduck notices is played
    /// at 30 dB too loud. A one-second interval produced exactly that: a full second
    /// of blast on hangup. Reading one property 20x a second costs nothing next to
    /// hurting someone wearing headphones.
    private static let pollInterval = 0.05

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        // Two cadences on one timer: evaluate every tick (cheap — one property read,
        // and the safety of the whole app rests on it), but only retry attachment
        // once a second, because that path shells out to pgrep and spawning a
        // process 20 times a second to find a daemon that is not running is absurd.
        var tick = 0
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            tick += 1
            if self.daemonObject == nil {
                if tick % Int(1.0 / Self.pollInterval) == 0 { self.attach() }
            } else {
                self.evaluate()
            }
        }
        timer.resume()
        poll = timer
    }

    private func evaluate() {
        guard let object = daemonObject else { return }
        let running = readProperty(object, address(kAudioProcessPropertyIsRunningInput), default: UInt32(0)) != 0
        guard running != isOnCall else { return }
        isOnCall = running
        if !running { onCallEndedImmediate?() }
        let value = running
        DispatchQueue.main.async { [weak self] in self?.onChange?(value) }
    }
}
