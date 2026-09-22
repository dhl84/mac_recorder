import AVFoundation

/// Finds the place where one recording holds two calls.
///
/// The Mac version has two tracks and asks where both go quiet together, which is
/// strong evidence. An iPhone records one track, so the only evidence here is a
/// long silence. A long pause inside one call looks the same, so the app shows
/// each candidate and the user decides.
enum Split {
    /// Root mean square level for each window of the file, in decibels.
    static func levels(_ url: URL, window: Double = 0.25) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let frames = AVAudioFrameCount(rate * window)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                        frameCapacity: frames) else { return [] }
        var out: [Float] = []
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else { break }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            out.append(20 * log10(max(rms, 1e-7)))
        }
        return out
    }

    /// Returns the middle of each quiet spell that lasts `gap` seconds or more.
    /// The cut goes in the middle, so neither call loses a word.
    static func quiet(_ levels: [Float], window: Double = 0.25,
                      floor: Float = -45, gap: Double = 20) -> [Double] {
        var out: [Double] = []
        var run = 0
        for (i, level) in levels.enumerated() {
            if level < floor {
                run += 1
                continue
            }
            out.append(contentsOf: mark(run: run, endingBefore: i, window: window, gap: gap))
            run = 0
        }
        out.append(contentsOf: mark(run: run, endingBefore: levels.count, window: window, gap: gap))
        return out
    }

    private static func mark(run: Int, endingBefore end: Int, window: Double, gap: Double) -> [Double] {
        let seconds = Double(run) * window
        guard seconds >= gap else { return [] }
        let start = Double(end - run) * window
        // A quiet spell that runs to the end of the file is the tail, not a join.
        return [((start + start + seconds) / 2 * 10).rounded() / 10]
    }

    /// Writes one folder for each part. The original folder stays.
    static func apply(_ session: Session, at cuts: [Double]) throws -> [URL] {
        let file = try AVAudioFile(forReading: session.audio)
        let format = file.processingFormat
        let rate = format.sampleRate
        let edges = [0.0] + cuts + [Double(file.length) / rate]
        var made: [URL] = []
        for i in 0..<(edges.count - 1) {
            let start = AVAudioFramePosition(edges[i] * rate)
            let frames = AVAudioFrameCount((edges[i + 1] - edges[i]) * rate)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
            else { continue }
            file.framePosition = start
            try file.read(into: buffer, frameCount: frames)
            let part = session.url.deletingLastPathComponent()
                .appendingPathComponent("\(session.url.lastPathComponent)-\(i + 1)")
            try FileManager.default.createDirectory(at: part, withIntermediateDirectories: true)
            let out = try AVAudioFile(forWriting: part.appendingPathComponent("audio.wav"),
                                      settings: Recorder.settings)
            try out.write(from: buffer)
            Store.writeMeta(folder: part, label: "",
                            date: session.date.addingTimeInterval(edges[i]),
                            duration: edges[i + 1] - edges[i])
            made.append(part)
        }
        return made
    }
}
