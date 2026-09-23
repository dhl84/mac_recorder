import Foundation

/// Removes what the model wrote that the transcript does not support.
///
/// A small on-device model, given six words of speech, filled every section with
/// text from the instructions: an example timestamp, an example salary and a
/// project manager nobody mentioned. A prompt cannot stop that, so this check
/// runs after the model and keeps a line only when the transcript backs it.
enum Grounding {
    /// Under this many words there is nothing to summarise, and the model is not asked.
    static let minimumWords = 40

    private static let common: Set<String> = [
        "about", "after", "again", "also", "because", "been", "before", "being", "call",
        "could", "does", "done", "each", "from", "have", "into", "just", "like", "made",
        "make", "more", "most", "none", "only", "other", "over", "said", "same", "should",
        "some", "speaker", "such", "than", "that", "their", "them", "then", "there", "these",
        "they", "this", "those", "through", "unstated", "very", "want", "were", "what",
        "when", "where", "which", "while", "will", "with", "would", "your",
    ]

    /// The words a line must share with the transcript: four letters or more, not common.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !common.contains($0) && Int($0) == nil }
    }

    static func numbers(_ text: String) -> Set<String> {
        Set(text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty })
    }

    /// A word counts when the transcript holds a word with the same first five
    /// letters, so "reviewed" matches "review" and "salaries" matches "salary".
    private static func grounded(_ word: String, in stems: Set<String>) -> Bool {
        stems.contains(String(word.prefix(5)))
    }

    /// Returns the reason a bullet fails, or nil when the transcript backs it.
    static func failure(_ line: String, transcript: String, duration: Double) -> String? {
        var body = line.trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("- ") { body.removeFirst(2) }
        if ["none", "none stated", "nothing relevant"].contains(body.lowercased()) { return nil }

        // A leading [mm:ss] or [hh:mm:ss] must fall inside the recording.
        if let match = body.range(of: #"^\[\d{1,2}:\d{2}(:\d{2})?\]\s*"#, options: .regularExpression) {
            let parts = body[match].filter { $0.isNumber || $0 == ":" }
                .split(separator: ":").map { Double($0) ?? 0 }
            let seconds = parts.reduce(0) { $0 * 60 + $1 }
            if seconds > duration + 5 { return "timestamp past the end" }
            body.removeSubrange(match)
        }
        // An [owner] tag names a person, which the word test covers below.
        body = body.replacingOccurrences(of: #"^\[[^\]]*\]\s*"#, with: "", options: .regularExpression)

        let said = numbers(transcript)
        if let stray = numbers(body).first(where: { !said.contains($0) }) {
            return "number \(stray) not in the transcript"
        }
        let own = words(body)
        guard !own.isEmpty else { return "no checkable words" }
        let stems = Set(words(transcript).map { String($0.prefix(5)) })
        let hits = own.filter { grounded($0, in: stems) }.count
        if Double(hits) / Double(own.count) < 0.5 {
            return "\(hits) of \(own.count) words in the transcript"
        }
        return nil
    }

    /// Keeps the headings, drops the unsupported lines and repeats, and writes
    /// "- none" under a section that ends up empty.
    static func clean(_ brief: String, transcript: String, duration: Double) -> String {
        var out: [String] = []
        var seen: Set<String> = []
        var kept = 0
        var inSection = false

        func closeSection() {
            if inSection && kept == 0 { out.append("- none") }
        }

        for raw in brief.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                closeSection()
                out.append("")
                out.append(line)
                inSection = true
                kept = 0
                continue
            }
            if line.isEmpty || !inSection { continue }
            let key = line.lowercased()
            if seen.contains(key) { continue }
            if failure(line, transcript: transcript, duration: duration) != nil { continue }
            seen.insert(key)
            out.append(line.hasPrefix("- ") || !line.hasPrefix("-") ? line : "- " + line)
            kept += 1
        }
        closeSection()
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The brief for a recording too short to summarise. No model runs.
    static func tooShort(words count: Int) -> String {
        let none = ["The point", "Decisions", "Actions", "Key points", "Facts and numbers", "Open questions"]
            .map { "## \($0)\n\n- none" }
            .joined(separator: "\n\n")
        return "The transcript holds \(count) words, under the \(minimumWords) a brief needs, "
            + "so no model ran.\n\n" + none
    }
}
