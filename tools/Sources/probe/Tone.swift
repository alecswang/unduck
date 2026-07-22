import AVFoundation
import Foundation

/// Reference signal generator. Plays a steady sine at a known dBFS so the meters
/// have something with a known level to compare against.
final class TonePlayer {
    private let engine = AVAudioEngine()
    private var phase: Double = 0

    /// - Parameter voiceProcessing: render through the VoiceProcessingIO unit, the
    ///   same unit FaceTime uses. FaceTime's own output is audibly not ducked, so
    ///   the question is whether being a "voice" client is what buys the exemption.
    ///   If it is, Unduck can render its mix this way and skip gain compensation
    ///   entirely.
    func start(frequency: Double = 440, dbfs: Double, voiceProcessing: Bool = false) throws {
        if voiceProcessing {
            // Voice processing belongs to the input/output pair, not to one node.
            // The input node has to be instantiated first or enabling it on output
            // throws; enabling either side turns on the other automatically.
            // Enable on the input node ONLY. Enabling one side turns on the other,
            // and calling it a second time re-initializes the unit and fails with
            // -10875 at kAUInitialize.
            try engine.inputNode.setVoiceProcessingEnabled(true)
        }
        let output = engine.outputNode
        // Read the format only after the switch: VoiceProcessingIO changes the
        // node's sample rate and channel count out from under you.
        let format = output.inputFormat(forBus: 0)
        let sampleRate = format.sampleRate > 0 ? format.sampleRate : 48000
        let amplitude = pow(10, dbfs / 20)
        let increment = 2 * Double.pi * frequency / sampleRate

        let source = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let value = Float(sin(self.phase) * amplitude)
                self.phase += increment
                if self.phase > 2 * Double.pi { self.phase -= 2 * Double.pi }
                for buffer in buffers {
                    buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = value
                }
            }
            return noErr
        }

        engine.attach(source)
        let channels = max(1, format.channelCount)
        engine.connect(source, to: engine.mainMixerNode,
                       format: AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        try engine.start()
        Swift.print("tone engine: \(sampleRate) Hz x\(channels)\(voiceProcessing ? " (VoiceProcessingIO)" : "")")
    }

    func stop() {
        engine.stop()
    }
}
