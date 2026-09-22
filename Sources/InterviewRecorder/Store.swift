import Foundation

/// One recorded call on disk: a folder with mic.wav, system.wav, meta.json and,
/// after transcription, transcript.md.
struct Session: Identifiable, Hashable {
    let url: URL
    var label: String
    var date: Date
    var duration: TimeInterval
    var id: URL { url }

    var transcript: URL { url.appendingPathComponent("transcript.md") }
    var brief: URL { url.appendingPathComponent("brief.md") }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcript.path) }
    var hasBrief: Bool { FileManager.default.fileExists(atPath: brief.path) }
    var sizeMB: Double {
        var bytes = 0
        for name in ["mic.wav", "system.wav"] {
            let path = url.appendingPathComponent(name).path
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attributes[.size] as? Int { bytes += size }
        }
        return Double(bytes) / 1_048_576
    }
}

enum Store {
    /// Recordings live outside the code repositories, because a call is private
    /// and a repository is not the place for it.
    static let root: URL = {
        if let custom = ProcessInfo.processInfo.environment["INTERVIEW_RECORDER_HOME"] {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/InterviewRecorder")
    }()

    /// The dataset folder. One folder for each role.
    static let dataset: URL = {
        if let custom = ProcessInfo.processInfo.environment["INTERVIEW_DATASET"] {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/InterviewDataset")
    }()

    static func slug(_ text: String) -> String {
        let lower = text.lowercased()
        let kept = lower.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(kept)
        let parts = joined.split(separator: "-").map(String.init)
        return parts.joined(separator: "-")
    }

    static func folderName(label: String, date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        return "\(f.string(from: date))-\(slug(label))"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    static func writeMeta(folder: URL, label: String, date: Date, duration: TimeInterval) {
        let meta: [String: Any] = [
            "label": label,
            "started": ISO8601DateFormatter().string(from: date),
            "duration": duration,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) else { return }
        try? data.write(to: folder.appendingPathComponent("meta.json"))
    }

    /// Reads every session folder. A folder without meta.json still appears, so
    /// an interrupted recording is never invisible.
    static func list() -> [Session] {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [Session] = []
        for url in items where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let metaURL = url.appendingPathComponent("meta.json")
            var label = url.lastPathComponent
            var date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            var duration: TimeInterval = 0
            if let data = try? Data(contentsOf: metaURL),
               let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                label = meta["label"] as? String ?? label
                duration = meta["duration"] as? TimeInterval ?? 0
                if let text = meta["started"] as? String,
                   let parsed = ISO8601DateFormatter().date(from: text) { date = parsed }
            }
            out.append(Session(url: url, label: label, date: date, duration: duration))
        }
        return out
    }

    static func delete(_ session: Session) {
        try? FileManager.default.trashItem(at: session.url, resultingItemURL: nil)
    }
}
