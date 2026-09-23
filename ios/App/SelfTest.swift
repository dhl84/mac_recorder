import SwiftUI

/// The checks that need no microphone, no model and no network: the naming, the
/// transcript layout, the chunking and the split maths. Open it from the menu.
enum SelfTest {
    struct Check: Identifiable {
        let id = UUID()
        let name: String
        let passed: Bool
        let detail: String
    }

    static func run() -> [Check] {
        var out: [Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            out.append(Check(name: name, passed: passed, detail: passed ? "" : detail))
        }

        check("clock", Store.clock(3_661) == "01:01:01", Store.clock(3_661))
        check("stamp", Store.stamp(754) == "12:34", Store.stamp(754))
        check("slug", Store.slug("Acme — Finance Lead!") == "acme-finance-lead",
              Store.slug("Acme — Finance Lead!"))
        check("folder name with a label",
              Store.folderName(label: "Acme Ltd", date: Date(timeIntervalSince1970: 1_600_000_000))
                .hasSuffix("-acme-ltd"))
        check("folder name with no label",
              !Store.folderName(label: "", date: Date(timeIntervalSince1970: 1_600_000_000)).hasSuffix("-"))

        // The transcript opens a heading every 30 seconds, not on every line.
        let session = Session(url: URL(fileURLWithPath: "/tmp/x"), label: "Test",
                              date: Date(timeIntervalSince1970: 0), duration: 90)
        let text = Transcribe.render(session, lines: [
            .init(start: 0, text: "Hello."),
            .init(start: 5, text: "Shall we start?"),
            .init(start: 44, text: "Yes."),
        ])
        check("one heading for each 30 seconds",
              text.components(separatedBy: "\n## ").count - 1 == 2,
              "\(text.components(separatedBy: "\n## ").count - 1) headings")
        check("lines inside one window join", text.contains("Hello. Shall we start?"))
        check("the second window opens at its own time", text.contains("## 00:44"))
        check("the length shows as a clock", text.contains("Length 00:01:30"))

        check("chunking splits on the word count",
              Brief.chunks(Array(repeating: "word", count: 3_000).joined(separator: " "),
                           size: 1_400).count == 3)
        check("chunking keeps a short text whole",
              Brief.chunks("one two three", size: 1_400).count == 1)
        check("a title loses its wrapper", Brief.clean("\"Title: Board pay review\"") == "Board pay review",
              Brief.clean("\"Title: Board pay review\""))
        check("a title loses a trailing stop", Brief.clean("Board pay review.") == "Board pay review")

        // Split: 0.25 second windows. Quiet is under -45 dB.
        let loud: Float = -20, hush: Float = -60
        var levels = [Float](repeating: loud, count: 400)      // 100 seconds
        levels.replaceSubrange(200..<300, with: [Float](repeating: hush, count: 100))  // 25 s quiet
        let cuts = Split.quiet(levels, window: 0.25, floor: -45, gap: 20)
        check("one quiet spell gives one cut", cuts.count == 1, "\(cuts)")
        check("the cut is the middle of the quiet", cuts.first == 62.5, "\(cuts.first ?? -1)")
        check("a short pause is no join",
              Split.quiet(levels, window: 0.25, floor: -45, gap: 30).isEmpty)
        check("a loud file gives no cut",
              Split.quiet([Float](repeating: loud, count: 400), window: 0.25, floor: -45, gap: 20).isEmpty)
        // The brief the on-device model wrote for "hello? hello? testing 1, 2, 3" on
        // 2026-09-23. Every line came from the prompt, not from the speech.
        let said = "Hello? Hello? Testing 1, 2, 3."
        let invented = """
            ## The point
            The call settled an issue with a project.

            ## Decisions
            - [01:12] - a speaker: The project will proceed with the current timeline.

            ## Actions
            - [01:12] - a speaker: The project manager will review the current progress and report back to the team.

            ## Key points
            - [01:12] - a speaker: The project manager will review the current progress and report back to the team.
            - [01:12] - a speaker: The project manager will review the current progress and report back to the team.

            ## Facts and numbers
            - 40: the agreed price in pounds.

            ## Open questions
            - [01:12] - a speaker: Are there any other concerns or issues that need to be addressed before the project begins?
            """
        let cleaned = Grounding.clean(invented, transcript: said, duration: 5)
        let survivors = cleaned.components(separatedBy: "\n")
            .filter { $0.hasPrefix("- ") && $0 != "- none" }
        check("the invented brief loses every line", survivors.isEmpty, survivors.joined(separator: " | "))
        check("each emptied section says none",
              cleaned.components(separatedBy: "- none").count - 1 == 6, cleaned)
        check("a timestamp past the end fails",
              Grounding.failure("- [01:12] Testing hello", transcript: said, duration: 5) != nil)
        check("an hh:mm:ss stamp inside the call stays",
              Grounding.failure("- [00:00:04] The salary is agreed", transcript: "the salary is agreed", duration: 30) == nil)
        check("an hh:mm:ss stamp past the end fails",
              Grounding.failure("- [00:01:12] The salary is agreed", transcript: "the salary is agreed", duration: 30) != nil)
        check("a number the call never said fails",
              Grounding.failure("- 40: the agreed price", transcript: "the salary is agreed", duration: 90) != nil)
        check("six words never reach the model",
              said.split(whereSeparator: \.isWhitespace).count < Grounding.minimumWords)

        // A line the transcript does back must survive, or the check is useless.
        let real = "We agreed the price at 40 pounds. Sarah will send the contract by Friday."
        check("a supported decision stays",
              Grounding.failure("- [00:04] The price is agreed at 40 pounds", transcript: real, duration: 30) == nil,
              Grounding.failure("- [00:04] The price is agreed at 40 pounds", transcript: real, duration: 30) ?? "")
        check("a supported action stays",
              Grounding.failure("- [Sarah] Send the contract, by Friday", transcript: real, duration: 30) == nil,
              Grounding.failure("- [Sarah] Send the contract, by Friday", transcript: real, duration: 30) ?? "")
        return out
    }
}

struct SelfTestView: View {
    @Environment(\.dismiss) private var dismiss
    private let checks = SelfTest.run()

    var body: some View {
        NavigationStack {
            List(checks) { check in
                HStack(alignment: .top) {
                    Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.passed ? .green : .red)
                    VStack(alignment: .leading) {
                        Text(check.name)
                        if !check.detail.isEmpty {
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("\(checks.filter(\.passed).count) of \(checks.count) passed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Runs the checks, or one transcription, from a launch argument. There is no
/// terminal on an iPhone, so this is how the build gets tested without taps:
///
///     xcrun simctl launch --console <device> com.davidlee.InterviewRecorder --self-test
enum Headless {
    static func runIfAsked() {
        let args = CommandLine.arguments
        if args.contains("--self-test") {
            let checks = SelfTest.run()
            for check in checks where !check.passed {
                print("FAIL \(check.name): \(check.detail)")
            }
            let passed = checks.filter(\.passed).count
            print("self-test: \(passed) of \(checks.count) passed")
            exit(passed == checks.count ? 0 : 1)
        }
    }

    /// The folder named by --transcribe, if the argument is there.
    static var demoFolder: URL? {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--transcribe"), flag + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[flag + 1])
    }

    /// Transcribes that folder and exits. It runs from the first view, not from
    /// init, because the speech daemon ignores an app that is still launching.
    static func transcribeDemo(_ folder: URL) async {
        let meta = Store.readMeta(folder)
        let session = Session(url: folder, label: meta["label"] as? String ?? "",
                              date: Date(), duration: meta["duration"] as? TimeInterval ?? 0)
        do {
            print("locale: \(Locale.current.identifier)")
            let out = try await Transcribe.run(session) { print($0) }
            print(try String(contentsOf: out, encoding: .utf8))
            print("demo: wrote \(out.lastPathComponent)")
            exit(0)
        } catch {
            print("demo FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }
}
