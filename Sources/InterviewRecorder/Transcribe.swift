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

    static var binary: String {
        for path in ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        return "whisper-cli"
    }

    struct Line {
        let start: Double
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
            let result = shell(binary, ["-m", model, "-f", wav.path, "-l", "auto",
                                       "-osrt", "-of", stem.path, "-np"])
            guard result.code == 0 else {
                throw fail("whisper-cli failed on \(file): \(result.err.suffix(400))")
            }
            let srt = stem.appendingPathExtension("srt")
            let text = (try? String(contentsOf: srt, encoding: .utf8)) ?? ""
            lines += parse(text, speaker: speaker)
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
            guard let seconds = seconds(stampRow) else { continue }
            let body = (Int(rows[0]) != nil ? rows.dropFirst(2) : rows.dropFirst(1))
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if body.isEmpty || body == "[BLANK_AUDIO]" { continue }
            out.append(Line(start: seconds, speaker: speaker, text: body))
        }
        return out
    }

    private static func seconds(_ row: String) -> Double? {
        guard let arrow = row.range(of: "-->") else { return nil }
        let stamp = row[row.startIndex..<arrow.lowerBound]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = stamp.split(separator: ":").map(String.init)
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2])
        else { return nil }
        return h * 3_600 + m * 60 + s
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
