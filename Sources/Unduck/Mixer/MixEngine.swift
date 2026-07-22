import AVFoundation
import CoreAudio
import Foundation

/// Takes over every audio source during a call and re-renders them under Unduck's
/// own gains.
///
/// The shape is dictated by three measured facts (docs/measurements.md):
///
///  * A muted tap still receives the source at **full, unducked level**, so the
///    captured signal is pristine — nothing to undo on the way in.
///  * Anything Unduck renders is ducked by exactly **30 dB**, same as everyone
///    else. That is what has to be compensated on the way out.
///  * The duck is a fixed gain, not compression, so a fixed makeup is correct.
///
/// Two buses, because two faders is the actual product: the call voice
/// (`avconferenced`) and everything else.
final class MixEngine {
    struct Levels {
        var call: Float = 1.0
        var media: Float = 1.0
        var master: Float = 1.0
    }

    var levels = Levels() {
        didSet { updateGains() }
    }

    private let engine = AVAudioEngine()
    private var callTap: ProcessTap?
    private var mediaTap: ProcessTap?
    private let callBuffer = RingBuffer(capacity: 48000 * 2 * 2)   // ~2s stereo
    private let mediaBuffer = RingBuffer(capacity: 48000 * 2 * 2)
    private var sourceNode: AVAudioSourceNode?
    private var running = false

    /// Extra gain applied to our own output to undo the system duck, in linear
    /// terms. Set by the controller once it knows how much the hardware volume
    /// could absorb.
    private var makeupGain: Float = 1.0
    private var callGain: Float = 1.0
    private var mediaGain: Float = 1.0

    /// Peak-following limiter state. Boosting to undo a 30 dB duck will clip
    /// anything mastered near full scale, so the makeup is backed off dynamically
    /// rather than allowed to distort.
    private var limiterGain: Float = 1.0

    private(set) var lastError: String?

    /// Input/output levels, logged once a second while engaged.
    ///
    /// The whole gain structure rests on how much attenuation the captured audio has
    /// already suffered before Unduck sees it. Guessing that from listening tests is
    /// how the first compensation figure came out wrong, so the engine reports what
    /// it actually receives.
    private let mediaMeter = BusMeter()
    private let callMeter = BusMeter()
    private let outputMeter = BusMeter()
    private var levelTimer: DispatchSourceTimer?

    /// Most recent media-bus peak in dBFS, refreshed once a second.
    ///
    /// This exists because `kAudioProcessPropertyIsRunningOutput` is not a reliable
    /// "is it playing" signal: Spotify clears it when paused, but Chrome keeps its
    /// audio IO open and the flag stays true over a paused video. Level is the only
    /// honest answer.
    private(set) var lastMediaPeakDB: Double = -.infinity

    final class BusMeter {
        private var sumSquares: Double = 0
        private var count = 0
        private var peak: Float = 0
        private let lock = NSLock()

        func add(_ samples: UnsafePointer<Float>, count n: Int) {
            var s: Double = 0
            var p: Float = 0
            for i in 0..<n {
                let v = samples[i]
                s += Double(v) * Double(v)
                let a = abs(v)
                if a > p { p = a }
            }
            lock.lock()
            sumSquares += s; count += n
            if p > peak { peak = p }
            lock.unlock()
        }

        func drain() -> (rms: Double, peak: Double) {
            lock.lock()
            let s = sumSquares, c = count, p = peak
            sumSquares = 0; count = 0; peak = 0
            lock.unlock()
            guard c > 0 else { return (-.infinity, -.infinity) }
            let rms = (s / Double(c)).squareRoot()
            return (db(rms), db(Double(p)))
        }

        private func db(_ linear: Double) -> Double { linear <= 0 ? -.infinity : 20 * log10(linear) }
    }

    private func startLevelLogging(makeupDB: Float) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "unduck.levels"))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let m = self.mediaMeter.drain(), c = self.callMeter.drain(), o = self.outputMeter.drain()
            self.lastMediaPeakDB = m.peak
            Log.write(String(format: "levels  media in %6.1f/%6.1f  call in %6.1f/%6.1f  out %6.1f/%6.1f  (makeup %.0f dB, limiter %.2f)",
                             m.rms, m.peak, c.rms, c.peak, o.rms, o.peak, makeupDB, self.limiterGain))
        }
        timer.resume()
        levelTimer = timer
    }

    func start(makeupDB: Float) throws {
        guard !running else { return }
        lastError = nil
        makeupGain = pow(10, makeupDB / 20)
        limiterGain = 1.0
        lastMediaPeakDB = -.infinity
        callBuffer.clear()
        mediaBuffer.clear()
        updateGains()

        let selfObject = try processObject(forPID: getpid())
        let callObjects = pids(matching: CallDetector.daemonName).compactMap { try? processObject(forPID: $0) }

        // Everything that is not us and not the call: one muted global tap with the
        // call daemon excluded, so new media apps are picked up without rescanning.
        mediaTap = try ProcessTap(label: "media", target: .allExcept([selfObject] + callObjects), mute: true)
        try mediaTap?.start { [weak self] samples, frames, channels in
            self?.mediaMeter.add(samples, count: frames * channels)
            self?.mediaBuffer.write(samples, count: frames * channels)
        }

        if !callObjects.isEmpty {
            callTap = try ProcessTap(label: "call", target: .processes(callObjects), mute: true)
            try callTap?.start { [weak self] samples, frames, channels in
                self?.callMeter.add(samples, count: frames * channels)
                self?.callBuffer.write(samples, count: frames * channels)
            }
        }

        try startOutput()
        startLevelLogging(makeupDB: makeupDB)
        running = true
    }

    /// Silences Unduck's own render immediately, without tearing anything down.
    ///
    /// Called first on the way out. While the hardware volume is still raised for
    /// compensation, our output is the loudest thing on the machine; muting it makes
    /// the restore sequence silent rather than a 30 dB blast. Sources stay muted
    /// until `stop()`, so nothing else fills the gap either.
    func silenceOutput() {
        callGain = 0
        mediaGain = 0
        makeupGain = 0
    }

    func stop() {
        guard running else { return }
        running = false
        levelTimer?.cancel()
        levelTimer = nil
        engine.stop()
        if let sourceNode { engine.detach(sourceNode) }
        sourceNode = nil
        // Destroying the taps is what un-mutes every source. It must happen on
        // every exit path, including errors, or the machine is left silent.
        callTap?.invalidate()
        mediaTap?.invalidate()
        callTap = nil
        mediaTap = nil
        callBuffer.clear()
        mediaBuffer.clear()
    }

    // MARK: - Render

    private func startOutput() throws {
        // Output only. `engine.inputNode` must never be touched: on this machine it
        // blocks forever inside AudioDeviceCreateIOProcID (see S6 in
        // docs/measurements.md), and Unduck does not need capture to mix playback.
        let output = engine.outputNode
        let format = output.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 48000
        let channels = max(1, format.channelCount)

        var callScratch = [Float](repeating: 0, count: 4096)
        var mediaScratch = [Float](repeating: 0, count: 4096)

        let node = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let interleavedCount = Int(frameCount) * Int(channels)

            if callScratch.count < interleavedCount { callScratch = [Float](repeating: 0, count: interleavedCount) }
            if mediaScratch.count < interleavedCount { mediaScratch = [Float](repeating: 0, count: interleavedCount) }

            callScratch.withUnsafeMutableBufferPointer { call in
                mediaScratch.withUnsafeMutableBufferPointer { media in
                    self.callBuffer.read(into: call.baseAddress!, count: interleavedCount)
                    self.mediaBuffer.read(into: media.baseAddress!, count: interleavedCount)

                    let callGain = self.callGain
                    let mediaGain = self.mediaGain
                    let makeup = self.makeupGain

                    // Mix, then apply makeup through the limiter.
                    var peak: Float = 0
                    for i in 0..<interleavedCount {
                        let mixed = (call[i] * callGain + media[i] * mediaGain) * makeup
                        call[i] = mixed
                        let magnitude = abs(mixed)
                        if magnitude > peak { peak = magnitude }
                    }

                    // Fast attack, slow release. Attack has to be immediate or the
                    // first transient clips; release is slow so the gain does not
                    // pump audibly between words.
                    let ceiling: Float = 0.98
                    let needed = peak > ceiling ? ceiling / peak : 1.0
                    if needed < self.limiterGain {
                        self.limiterGain = needed
                    } else {
                        self.limiterGain += (needed - self.limiterGain) * 0.02
                    }
                    let limiter = self.limiterGain

                    for i in 0..<interleavedCount { call[i] *= limiter }
                    self.outputMeter.add(call.baseAddress!, count: interleavedCount)

                    for frame in 0..<Int(frameCount) {
                        for (channelIndex, buffer) in buffers.enumerated() {
                            let sourceIndex = frame * Int(channels) + min(channelIndex, Int(channels) - 1)
                            buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = call[sourceIndex]
                        }
                    }
                }
            }
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        sourceNode = node
        try engine.start()
    }

    private func updateGains() {
        callGain = levels.call * levels.master
        mediaGain = levels.media * levels.master
    }

    var isRunning: Bool { running }
}
