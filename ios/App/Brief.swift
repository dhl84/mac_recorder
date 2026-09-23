import FoundationModels
import Foundation

/// Writes the title and the brief with the on-device model in iOS 26. The Mac
/// version asks Ollama. Neither sends the transcript anywhere.
enum Brief {
    /// The on-device model holds a few thousand tokens, so a long call goes in
    /// parts and the parts merge.
    static let chunkWords = 1_400

    static let style = """
        Write in Simple Technical English. One idea per sentence, 25 words at most. \
        Active voice, and name the actor. Plain words. Give the number. \
        Keep every name exactly as the speaker says it.
        """

    enum Ready {
        case yes
        case no(String)
    }

    static var ready: Ready {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .yes
        case .unavailable(let reason):
            return .no(explain(reason))
        @unknown default:
            return .no("The on-device model is not available on this iPhone.")
        }
    }

    private static func explain(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This iPhone does not run Apple Intelligence, so it writes no brief. The transcript still works."
        case .appleIntelligenceNotEnabled:
            return "Turn on Apple Intelligence in Settings to get a title and a brief."
        case .modelNotReady:
            return "The on-device model is still downloading. Try again in a few minutes."
        @unknown default:
            return "The on-device model is not available right now."
        }
    }

    // MARK: title

    /// Names a call the user left unnamed.
    static func title(_ session: Session) async throws -> String? {
        guard case .yes = ready else { return nil }
        let body = Transcribe.speech(session)
        guard !body.isEmpty else { return nil }
        let model = LanguageModelSession(instructions: """
            You name a recorded call from its transcript. Answer with the title alone.
            Between 5 and 12 words. Name the group or the organisation, and the subject.
            Write the subject, not the tone. No date, no quotation marks, no full stop.
            """)
        let reply = try await model.respond(to: chunks(body)[0]).content
        let name = clean(reply)
        guard (2...20).contains(name.split(separator: " ").count) else { return nil }
        Store.setLabel(name, on: session.url)
        return name
    }

    // MARK: brief

    static func write(_ session: Session, progress: @escaping (String) -> Void) async throws {
        guard case .yes = ready else {
            if case .no(let why) = ready { throw fail(why) }
            return
        }
        let body = Transcribe.speech(session)
        guard !body.isEmpty else { throw fail("Transcribe the call first.") }
        let label = session.label
        let head = "# \(label.isEmpty ? session.url.lastPathComponent : label)\n\n"

        let spoken = body.split(whereSeparator: \.isWhitespace).count
        if spoken < Grounding.minimumWords {
            try (head + Grounding.tooShort(words: spoken) + "\n")
                .write(to: session.brief, atomically: true, encoding: .utf8)
            return
        }

        let parts = chunks(body)
        var briefs: [String] = []
        for (i, part) in parts.enumerated() {
            progress("Part \(i + 1) of \(parts.count)…")
            let model = LanguageModelSession(instructions: briefInstructions)
            briefs.append(try await model.respond(to: "TRANSCRIPT:\n" + part).content)
        }

        var out = briefs[0]
        if briefs.count > 1 {
            progress("Merging \(briefs.count) parts…")
            let model = LanguageModelSession(instructions: """
                You merge briefs from consecutive parts of one call into one brief. \(style)
                Keep the same headings. Keep the timestamps. Remove each repeated point.
                """)
            out = try await model.respond(to: briefs.enumerated()
                .map { "--- PART \($0.offset + 1) ---\n\($0.element)" }
                .joined(separator: "\n\n")).content
        }

        let checked = Grounding.clean(out, transcript: body, duration: session.duration)
        try (head + "Brief from the on-device model. Every line below appears in the transcript.\n\n"
             + checked + "\n")
            .write(to: session.brief, atomically: true, encoding: .utf8)
    }

    // No example content anywhere in here. Given a near-empty transcript, the
    // model copied an example timestamp and an example salary into the brief.
    // Every format below uses placeholders, and no section asks for a count.
    private static let briefInstructions = """
        You write a brief of one recorded call from its transcript.
        \(style)
        Use only what the transcript says. Never copy words from these instructions into
        the brief. If the transcript gives nothing for a section, write "- none" under it.
        A short recording gives "- none" in most sections, and that is the right answer.
        The recording has one microphone track, so no line names a speaker. Use the names
        the transcript gives.

        Output this Markdown and nothing else:

        ## The point
        One sentence: what the call settled.

        ## Decisions
        One bullet for each thing the speakers agreed, as "- [mm:ss] what they agreed".
        mm:ss is the time in the transcript heading above those words.

        ## Actions
        One bullet for each task someone took on, as "- [who] the task, by when".
        Write "unstated" when the transcript gives no date.

        ## Key points
        At most eight bullets, as "- [mm:ss] the point". Fewer is better than padding.

        ## Facts and numbers
        One line for each amount, date or name the transcript states, as
        "- value: what it measures".

        ## Open questions
        At most four bullets. What the call left unsettled.
        """

    // MARK: helpers

    static func chunks(_ text: String, size: Int = chunkWords) -> [String] {
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return [""] }
        return stride(from: 0, to: words.count, by: size).map {
            words[$0..<min($0 + size, words.count)].joined(separator: " ")
        }
    }

    static func clean(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.components(separatedBy: "\n")[0]
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        if let range = name.range(of: "^(title|call)\\s*:\\s*", options: [.regularExpression, .caseInsensitive]) {
            name.removeSubrange(range)
        }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'. "))
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "CallNotes", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
