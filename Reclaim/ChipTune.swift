import AVFoundation

/// Tiny synthesized 8-bit jingle — a rising square-wave arpeggio, generated in
/// memory so we ship no audio assets.
@MainActor
enum ChipTune {
    private static var engine: AVAudioEngine?
    private static var stopTask: Task<Void, Never>?

    static func playScanComplete() {
        guard UserDefaults.standard.object(forKey: "playSounds") as? Bool ?? true else { return }
        // E5 → G5 → C6, coin-style.
        play(notes: [(659.26, 0.08), (783.99, 0.08), (1046.50, 0.18)])
    }

    private static func play(notes: [(frequency: Double, duration: Double)]) {
        stopTask?.cancel()
        engine?.stop()

        let sampleRate = 44_100.0
        let gap = 0.012
        let totalSeconds = notes.reduce(0) { $0 + $1.duration + gap }
        let frameCount = AVAudioFrameCount(totalSeconds * sampleRate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = frameCount

        var frame = 0
        for note in notes {
            let noteFrames = Int(note.duration * sampleRate)
            let period = sampleRate / note.frequency
            for i in 0..<noteFrames where frame + i < Int(frameCount) {
                // Square wave with a quick decay envelope: the 8-bit sound.
                let phase = Double(i).truncatingRemainder(dividingBy: period) / period
                let square: Float = phase < 0.5 ? 1 : -1
                let envelope = Float(1 - Double(i) / Double(noteFrames)) * 0.55 + 0.45
                samples[frame + i] = square * 0.042 * envelope
            }
            frame += noteFrames + Int(gap * sampleRate)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return
        }
        player.scheduleBuffer(buffer, at: nil)
        player.play()
        Self.engine = engine
        stopTask = Task {
            try? await Task.sleep(for: .seconds(totalSeconds + 0.3))
            guard !Task.isCancelled else { return }
            engine.stop()
            Self.engine = nil
        }
    }
}
