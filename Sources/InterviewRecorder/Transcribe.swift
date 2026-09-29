import Foundation

/// Runs whisper.cpp on the two tracks and merges them into one speaker-labelled
/// Markdown transcript.
enum Transcribe {
    static var model: String {
        if let custom = ProcessInfo.processInfo.environment["INTERVIEW_WHISPER_MODEL"] {
            return (custom as NSString).expandingTildeInPath
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ru.starmel.OpenSuperWhisper/whisper-models/ggml-large-v3-turbo.bin")
            .path
    }

    /// whisper invents speech over the quiet parts of a call. whisper.cpp offers
    /// --vad for this, and it does remove the invented text, but it also moves the
    /// timestamps: it cuts the silence out, transcribes the join, then maps the
    /// times back, and a segment then stretches across the gap between two turns.
    /// On the call of 29 September 2026 one segment covered 171 seconds and held a
    /// few words. The merge below sorts by time, so the two speakers came out in
    /// the wrong order and one sentence broke in half across a reply.
    ///
    /// So whisper runs with no VAD, which keeps the timestamps honest, and this gate
    /// drops the invented segments instead. Measured on both tracks of that call:
    /// 494 segments against 136, the text density rose from 5.5 to 10.4 characters
    /// for each second of span, and the gate removed 155 invented segments,
    /// including "I don't need you in the middle." 33 times over silence.
    struct Track {
        /// A segment whose loudest fifth of a second stays under this holds no speech.
        /// Real turns on that call measured 2,700 and above. Invented ones measured
        /// under 200, and most under 5.
        static let floor: Double = 150

        private let samples: [Int16]
        private let rate: Double

        /// Reads a 16-bit mono PCM WAV. Returns nil for any other shape, and the
        /// caller then keeps every segment rather than guess.
        init?(_ url: URL) {
            guard let data = try? Data(contentsOf: url), data.count > 44,
                  data.prefix(4) == Data("RIFF".utf8),
                  Data(data[8..<12]) == Data("WAVE".utf8) else { return nil }
            var offset = 12, channels = 0, bits = 0, hz = 0.0
            var body: Data?
            // Walk the chunks. A WAV can carry more than fmt and data.
            while offset + 8 <= data.count {
                let id = Data(data[offset..<offset + 4])
                let size = Int(Data(data[offset + 4..<offset + 8])
                    .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
                let start = offset + 8
                if id == Data("fmt ".utf8), start + 16 <= data.count {
                    let fmt = Data(data[start..<start + 16])
                    fmt.withUnsafeBytes { raw in
                        channels = Int(raw.loadUnaligned(fromByteOffset: 2, as: UInt16.self).littleEndian)
                        hz = Double(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian)
                        bits = Int(raw.loadUnaligned(fromByteOffset: 14, as: UInt16.self).littleEndian)
                    }
                } else if id == Data("data".utf8) {
                    body = Data(data[start..<min(start + size, data.count)])
                }
                offset = start + size + (size % 2)
                if size <= 0 { break }
            }
            guard channels == 1, bits == 16, hz > 0, let raw = body, raw.count >= 2 else { return nil }
            var out = [Int16](repeating: 0, count: raw.count / 2)
            raw.withUnsafeBytes { buffer in
                for i in 0..<out.count {
                    out[i] = buffer.loadUnaligned(fromByteOffset: i * 2, as: Int16.self).littleEndian
                }
            }
            samples = out
            rate = hz
        }

        /// The loudest fifth of a second in a range. A peak, not a mean, so a short
        /// answer inside a long span still counts as speech. A range shorter than the
        /// window measures whole: "Yeah." can last a tenth of a second, and a zero here
        /// would drop it as invented text.
        func peak(from: Double, to: Double) -> Double {
            let start = max(0, Int(from * rate))
            let end = min(Int(to * rate), samples.count)
            guard end > start else { return 0 }
            let window = min(max(1, Int(rate * 0.2)), end - start)
            var index = start
            var best = 0.0
            while index + window <= end {
                var sum = 0.0
                for k in index..<(index + window) {
                    let value = Double(samples[k])
                    sum += value * value
                }
                best = max(best, (sum / Double(window)).squareRoot())
                index += window
            }
            return best
        }
    }

    static var binary: String {
        for path in ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        return "whisper-cli"
    }

    struct Line {
        let start: Double
        var end: Double = 0
        let speaker: String
        let text: String
    }

    /// Transcribes both tracks and writes transcript.md. Returns the file, or
    /// throws with the reason.
    static func run(_ session: Session, progress: @escaping (String) -> Void) throws -> URL {
        guard FileManager.default.fileExists(atPath: model) else {
            throw fail("No whisper model at \(model). Set INTERVIEW_WHISPER_MODEL to a ggml .bin file.")
        }
        var lines: [Line] = []
        for (file, speaker) in [("mic.wav", "Me"), ("system.wav", "Them")] {
            let wav = session.url.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: wav.path) else { continue }
            progress("Transcribing \(file) as \(speaker)…")
            let stem = session.url.appendingPathComponent(speaker == "Me" ? "mic" : "system")
            // -mc 0 keeps no decoded text as the prompt for the next window. Carried
            // text is what holds whisper in a repetition loop: on 29 September 2026 the
            // system track gave "So, the third billion dollar company was in 1901."
            // 72 times across two minutes. With -mc 0 the worst loop fell to 15.
            let args = ["-m", model, "-f", wav.path, "-l", "auto",
                        "-osrt", "-of", stem.path, "-np", "-mc", "0"]
            let result = shell(binary, args)
            guard result.code == 0 else {
                throw fail("whisper-cli failed on \(file): \(result.err.suffix(400))")
            }
            let srt = stem.appendingPathExtension("srt")
            let text = (try? String(contentsOf: srt, encoding: .utf8)) ?? ""
            lines += gate(parse(text, speaker: speaker), wav: wav, progress: progress)
        }
        guard !lines.isEmpty else { throw fail("Both tracks are silent. Nothing to transcribe.") }
        lines.sort { $0.start < $1.start }
        let markdown = render(session, lines: lines)
        try markdown.write(to: session.transcript, atomically: true, encoding: .utf8)
        return session.transcript
    }

    /// Reads SRT and keeps the start time of each block. whisper.cpp writes one
    /// block for each segment, so a block needs no duplicate test.
    static func parse(_ srt: String, speaker: String) -> [Line] {
        var out: [Line] = []
        for block in srt.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n\n") {
            let rows = block.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            guard rows.count >= 2 else { continue }
            let stampRow = Int(rows[0]) != nil ? rows[1] : rows[0]
            guard let span = span(stampRow) else { continue }
            let body = (Int(rows[0]) != nil ? rows.dropFirst(2) : rows.dropFirst(1))
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body == "[BLANK_AUDIO]" { continue }
            out.append(Line(start: span.start, end: span.end, speaker: speaker, text: body))
        }
        return out
    }

    /// Removes the text whisper invents. Two tests, because one is not enough.
    ///
    /// The first drops a segment that sits over silence. The second drops a long line
    /// that repeats straight after itself, which is the tail of a repetition loop that
    /// -mc 0 does not reach. A loop can run over real sound, so loudness alone keeps it.
    /// A short line is exempt, because "Yeah." and "Okay." repeat in every real call.
    ///
    /// A track it cannot read keeps every segment, so a surprise never loses speech.
    static func gate(_ lines: [Line], wav: URL,
                     progress: (String) -> Void = { _ in }) -> [Line] {
        var kept = lines
        if let track = Track(wav) {
            kept = kept.filter { track.peak(from: $0.start, to: $0.end) >= Track.floor }
            if kept.count < lines.count {
                progress("Dropped \(lines.count - kept.count) invented segments over the quiet parts.")
            }
        } else {
            progress("Cannot read \(wav.lastPathComponent) for the loudness check. "
                     + "Keeping every segment, so the quiet parts may hold invented text.")
        }
        let before = kept.count
        var out: [Line] = []
        for line in kept {
            if let last = out.last, words(line.text).count >= 5,
               words(line.text) == words(last.text) { continue }
            out.append(line)
        }
        if out.count < before {
            progress("Dropped \(before - out.count) repeats of a line in a loop.")
        }
        return out
    }

    /// The words of a line, lowercased and without punctuation, for the repeat test.
    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func span(_ row: String) -> (start: Double, end: Double)? {
        guard let arrow = row.range(of: "-->") else { return nil }
        func clock(_ part: Substring) -> Double? {
            let parts = part.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",", with: ".")
                .split(separator: ":").map(String.init)
            guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]),
                  let s = Double(parts[2]) else { return nil }
            return h * 3_600 + m * 60 + s
        }
        guard let start = clock(row[row.startIndex..<arrow.lowerBound]) else { return nil }
        return (start, clock(row[arrow.upperBound...]) ?? start)
    }

    /// Joins the neighbour lines of one speaker, so the transcript reads as turns.
    static func render(_ session: Session, lines: [Line]) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH:mm"
        var out = """
        # \(session.label)

        Recorded \(stamp.string(from: session.date)). Length \(Store.clock(session.duration)).
        "Me" is the microphone track. "Them" is the system output track.

        """
        var speaker = ""
        for line in lines {
            if line.speaker != speaker {
                speaker = line.speaker
                out = out.trimmingCharacters(in: .whitespacesAndNewlines)
                out += "\n\n## \(Store.clock(line.start)) \(speaker)\n\n"
            }
            out += line.text + " "
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: dataset

    /// Copies the transcript into an application folder of the dataset and records one
    /// line in the dataset index.
    static func addToDataset(_ session: Session, folder rawFolder: String) throws -> URL {
        guard session.hasTranscript else { throw fail("Transcribe the session before you add it.") }
        let name = rawFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw fail("Name the application folder.") }
        let target = Store.dataset.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let file = target.appendingPathComponent("interview-transcript-\(stamp.string(from: session.date)).md")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.copyItem(at: session.transcript, to: file)

        let record: [String: Any] = [
            "label": session.label,
            "date": ISO8601DateFormatter().string(from: session.date),
            "duration": session.duration,
            "folder": name,
            "transcript": file.path,
            "source": session.url.path,
        ]
        let index = Store.dataset.appendingPathComponent("interviews.jsonl")
        if let data = try? JSONSerialization.data(withJSONObject: record),
           var row = String(data: data, encoding: .utf8) {
            row += "\n"
            if let handle = try? FileHandle(forWritingTo: index) {
                handle.seekToEndOfFile()
                handle.write(Data(row.utf8))
                try? handle.close()
            } else {
                try? row.write(to: index, atomically: true, encoding: .utf8)
            }
        }
        return file
    }

    static func datasetFolders() -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(at: Store.dataset,
                                                                  includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted()
    }

    // MARK: helpers

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "InterviewRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @discardableResult
    static func shell(_ launch: String, _ args: [String]) -> (code: Int32, out: String, err: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launch)
        task.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do { try task.run() } catch { return (127, "", error.localizedDescription) }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (task.terminationStatus,
                String(data: out, encoding: .utf8) ?? "",
                String(data: err, encoding: .utf8) ?? "")
    }
}
