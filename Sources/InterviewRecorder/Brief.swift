import Foundation

/// Calls callbrief.py, which holds the model prompts and the split maths.
/// The Swift side records audio and draws the window. The Python side talks to
/// Ollama and to ffmpeg, and it reuses the plumbing from the ytsum brief tool.
enum Brief {
    struct Boundary: Identifiable {
        let cut: Double
        let quietFrom: Double
        let quietTo: Double
        var id: Double { cut }
        var describe: String {
            "Cut at \(Store.clock(cut)). Both sides quiet from \(Store.clock(quietFrom)) to \(Store.clock(quietTo))."
        }
    }

    static var script: String {
        if let custom = ProcessInfo.processInfo.environment["INTERVIEW_CALLBRIEF"] {
            return (custom as NSString).expandingTildeInPath
        }
        if let inBundle = Bundle.main.url(forResource: "callbrief", withExtension: "py") {
            return inBundle.path
        }
        // A build that runs from .build/release, not from the bundle.
        return URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("../../Resources/callbrief.py").standardized.path
    }

    private static var python: String {
        for path in ["/opt/homebrew/bin/python3", "/usr/bin/python3"]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        return "/usr/bin/python3"
    }

    private static func call(_ args: [String]) throws -> String {
        guard FileManager.default.fileExists(atPath: script) else {
            throw NSError(domain: "InterviewRecorder", code: 3, userInfo:
                [NSLocalizedDescriptionKey: "No callbrief.py at \(script). Run ./build.sh again."])
        }
        let result = Transcribe.shell(python, [script] + args)
        guard result.code == 0 else {
            throw NSError(domain: "InterviewRecorder", code: 4, userInfo:
                [NSLocalizedDescriptionKey: String(result.err.suffix(400))])
        }
        return result.out
    }

    /// Names a call the user left unnamed. Returns the new label, or nil.
    @discardableResult
    static func title(_ session: Session, force: Bool = false) throws -> String? {
        let out = try call(["title", session.url.path] + (force ? ["--force"] : []))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    /// Writes brief.md beside the transcript.
    static func write(_ session: Session) throws {
        _ = try call(["brief", session.url.path])
    }

    /// Finds the places where the recording ran on from one call into the next.
    static func boundaries(_ session: Session, gap: Double = 8) throws -> [Boundary] {
        let out = try call(["split", session.url.path, "--gap", String(gap)])
        guard let data = out.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = top["boundaries"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let cut = row["cut"] as? Double,
                  let from = row["quiet_from"] as? Double,
                  let to = row["quiet_to"] as? Double else { return nil }
            return Boundary(cut: cut, quietFrom: from, quietTo: to)
        }
    }

    /// Cuts the two tracks into one folder for each call. The original stays.
    static func applySplit(_ session: Session, gap: Double = 8) throws -> [URL] {
        let out = try call(["split", session.url.path, "--gap", String(gap), "--apply"])
        guard let data = out.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = top["parts"] as? [String] else { return [] }
        return parts.map { URL(fileURLWithPath: $0) }
    }
}
