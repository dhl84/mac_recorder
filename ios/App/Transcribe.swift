import AVFoundation
import CoreMedia
import Speech

/// Transcribes a recording with the on-device speech model that ships with
/// iOS 26. Nothing leaves the phone, and no model download of gigabytes happens:
/// the system holds the assets and installs the locale on first use.
enum Transcribe {
    struct Line {
        let start: Double
        let text: String
    }

    /// Seconds between the timestamps kept in the transcript.
    static let stampEvery: Double = 30

    static func run(_ session: Session, progress: @escaping (String) -> Void) async throws -> URL {
        guard FileManager.default.fileExists(atPath: session.audio.path) else {
            throw fail("This call has no audio.wav.")
        }
        progress("Choosing the locale…")
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-GB")
        progress("Locale \(locale.identifier). Checking the speech assets…")
        let transcriber = SpeechTranscriber(locale: locale,
                                            preset: .timeIndexedTranscriptionWithAlternatives)

        // The app reserves the locale before it asks about the assets. The
        // installer refuses otherwise. The whole block is advisory: a simulator
        // cannot install speech assets, and the analysis still runs when the
        // system already holds them, so a failure here only gets reported.
        let status = await AssetInventory.status(forModules: [transcriber])
        progress("Locale \(locale.identifier). Assets: \(status).")
        if status != .installed {
            do {
                if await !AssetInventory.reservedLocales.contains(locale) {
                    _ = try await AssetInventory.reserve(locale: locale)
                }
                if let request = try await AssetInventory
                    .assetInstallationRequest(supporting: [transcriber]) {
                    progress("Installing the \(locale.identifier) speech model once…")
                    try await request.downloadAndInstall()
                }
            } catch {
                progress("The asset install did not run: \(error.localizedDescription)")
            }
        }

        // The analyzer picks its own format. Feeding it the file's format gives
        // "Audio format is not supported", so the file is converted on the way in.
        let file = try AVAudioFile(forReading: session.audio)
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [transcriber], considering: file.processingFormat) else {
            throw fail("This iPhone offers no speech format for \(locale.identifier). "
                       + "Turn on Apple Intelligence, or pick a different language in Settings.")
        }
        progress("Transcribing \(Store.clock(session.duration))…")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, feed) = AsyncStream<AnalyzerInput>.makeStream()

        // Collect before analysing. The results arrive while the file is read.
        let collector = Task { () -> [Line] in
            var lines: [Line] = []
            for try await result in transcriber.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
                if text.isEmpty { continue }
                lines.append(Line(start: result.range.start.seconds, text: text))
            }
            return lines
        }

        try await analyzer.start(inputSequence: stream)
        try feedFile(file, into: feed, as: target)
        feed.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()

        let lines = try await collector.value.sorted { $0.start < $1.start }
        guard !lines.isEmpty else { throw fail("The recording is silent. Nothing to transcribe.") }
        let markdown = render(session, lines: lines)
        try markdown.write(to: session.transcript, atomically: true, encoding: .utf8)
        return session.transcript
    }

    /// One heading every 30 seconds, so a reader can jump to a moment. There is
    /// one track, so no line carries a speaker.
    static func render(_ session: Session, lines: [Line]) -> String {
        let when = DateFormatter()
        when.dateFormat = "yyyy-MM-dd HH:mm"
        var out = """
        # \(session.label.isEmpty ? session.url.lastPathComponent : session.label)

        Recorded \(when.string(from: session.date)). Length \(Store.clock(session.duration)).
        One microphone track, so the transcript names no speaker.

        """
        var next = -1.0
        for line in lines {
            if line.start >= next {
                out = out.trimmingCharacters(in: .whitespacesAndNewlines)
                out += "\n\n## \(Store.stamp(line.start))\n\n"
                next = line.start + stampEvery
            }
            out += line.text + " "
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Reads the file in one second blocks and converts each block to the format
    /// the analyzer asked for. One converter lives for the whole file, because a
    /// new converter for each block restarts the resampler.
    private static func feedFile(_ file: AVAudioFile,
                                 into feed: AsyncStream<AnalyzerInput>.Continuation,
                                 as target: AVAudioFormat) throws {
        let source = file.processingFormat
        let block = AVAudioFrameCount(source.sampleRate)
        let converter = source == target ? nil : AVAudioConverter(from: source, to: target)
        let ratio = target.sampleRate / source.sampleRate
        var at = CMTime.zero

        while file.framePosition < file.length {
            // A fresh buffer each time, because the one just sent is still in use.
            guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: block) else { return }
            try file.read(into: input, frameCount: block)
            guard input.frameLength > 0 else { return }
            let seconds = Double(input.frameLength) / source.sampleRate

            var send = input
            if let converter {
                let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
                guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                var used = false
                var error: NSError?
                converter.convert(to: out, error: &error) { _, status in
                    if used { status.pointee = .noDataNow; return nil }
                    used = true
                    status.pointee = .haveData
                    return input
                }
                if let error { throw error }
                guard out.frameLength > 0 else { continue }
                send = out
            }
            feed.yield(AnalyzerInput(buffer: send, bufferStartTime: at))
            at = CMTimeAdd(at, CMTime(seconds: seconds, preferredTimescale: 1_000))
        }
    }

    /// The transcript without its header block, which is what the model reads.
    static func speech(_ session: Session) -> String {
        let text = (try? String(contentsOf: session.transcript, encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n## ").dropFirst().joined(separator: "\n")
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "CallNotes", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
