import Foundation

/// One recorded call on disk: a folder with audio.wav, meta.json and, after the
/// transcription, transcript.md and brief.md.
struct Session: Identifiable, Hashable {
    let url: URL
    var label: String
    var date: Date
    var duration: TimeInterval
    var id: URL { url }

    var audio: URL { url.appendingPathComponent("audio.wav") }
    var transcript: URL { url.appendingPathComponent("transcript.md") }
    var brief: URL { url.appendingPathComponent("brief.md") }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: transcript.path) }
    var hasBrief: Bool { FileManager.default.fileExists(atPath: brief.path) }

    var sizeMB: Double {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: audio.path),
              let size = attributes[.size] as? Int else { return 0 }
        return Double(size) / 1_048_576
    }
}

enum Store {
    /// The Documents folder, so the Files app and a Mac both reach the recordings.
    static let root: URL = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Calls")
    }()

    static func slug(_ text: String) -> String {
        let kept = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(kept).split(separator: "-").joined(separator: "-")
    }

    static func folderName(label: String, date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmm"
        let name = slug(label)
        return name.isEmpty ? f.string(from: date) : "\(f.string(from: date))-\(name)"
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
    }

    static func stamp(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func writeMeta(folder: URL, label: String, date: Date, duration: TimeInterval) {
        var meta = readMeta(folder)
        meta["label"] = label
        meta["started"] = ISO8601DateFormatter().string(from: date)
        meta["duration"] = duration
        write(meta, to: folder)
    }

    static func readMeta(_ folder: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return meta
    }

    static func write(_ meta: [String: Any], to folder: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted])
        else { return }
        try? data.write(to: folder.appendingPathComponent("meta.json"))
    }

    static func setLabel(_ label: String, on folder: URL) {
        var meta = readMeta(folder)
        meta["label"] = label
        meta["titleAuto"] = true
        write(meta, to: folder)
    }

    /// Reads every folder. A folder with no meta.json still appears, so an
    /// interrupted recording is never invisible.
    static func list() -> [Session] {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let items = (try? fm.contentsOfDirectory(at: root,
                                                 includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var out: [Session] = []
        for url in items where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let meta = readMeta(url)
            let label = meta["label"] as? String ?? ""
            var date = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? Date()
            if let text = meta["started"] as? String,
               let parsed = ISO8601DateFormatter().date(from: text) { date = parsed }
            out.append(Session(url: url, label: label, date: date,
                               duration: meta["duration"] as? TimeInterval ?? 0))
        }
        return out
    }

    static func delete(_ session: Session) {
        try? FileManager.default.removeItem(at: session.url)
    }
}
