import AppKit
import SwiftUI

/// Runs coach.py beside a recording and shows its notes in a small floating panel.
/// The panel never takes the keyboard focus, and a screen share or a screenshot
/// does not show it.
final class Coach: ObservableObject {
    struct Note: Identifiable {
        let id: Int
        let clock: String
        let kind: String
        let text: String
    }

    @Published private(set) var notes: [Note] = []
    @Published private(set) var status = ""

    /// On by default. The toolbar switch writes the same key.
    static var enabled: Bool { UserDefaults.standard.object(forKey: "coach") as? Bool ?? true }

    private var process: Process?
    private var file: URL?
    private var offset: UInt64 = 0
    private var timer: Timer?
    private var panel: NSPanel?

    static var script: String {
        if let inBundle = Bundle.main.url(forResource: "coach", withExtension: "py") { return inBundle.path }
        return (Brief.script as NSString).deletingLastPathComponent + "/coach.py"
    }

    /// Call on the main thread.
    func start(folder: URL, label: String, extra: [String] = []) {
        stop()
        notes = []
        status = "The coach starts. The first note comes after about 30 seconds of speech."
        offset = 0
        file = folder.appendingPathComponent("coach.jsonl")
        let log = folder.appendingPathComponent("coach.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Brief.python)
        p.arguments = [Coach.script, "run", folder.path, "--label", label] + extra
        // Finder starts the app with no shell variables, so the folder of application
        // folders can come from the app's settings instead (see the README).
        var env = ProcessInfo.processInfo.environment
        if env["COACH_APPLICATIONS"] == nil,
           let apps = UserDefaults.standard.string(forKey: "coachApplications"), !apps.isEmpty {
            env["COACH_APPLICATIONS"] = (apps as NSString).expandingTildeInPath
        }
        p.environment = env
        if let handle = try? FileHandle(forWritingTo: log) {
            p.standardOutput = handle
            p.standardError = handle
        }
        do {
            try p.run()
            process = p
        } catch {
            status = "The coach did not start: \(error.localizedDescription)"
        }
        show()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Fake notes for `--coach-snapshot`, so the panel layout can be checked.
    func preview() {
        notes = [Note(id: 2, clock: "12:40", kind: "wrap",
                      text: "Land it: the report went from two days to two hours. Then stop."),
                 Note(id: 1, clock: "11:05", kind: "missing",
                      text: "Say the result: the team kept the old price after your analysis."),
                 Note(id: 0, clock: "09:30", kind: "answer",
                      text: "Why Acme: the product launched in three new markets this year.")]
        status = "claude-fable-5-1 reads acme-finance-manager-20261001"
    }

    func stop() {
        process?.terminate()
        process = nil
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
    }

    /// Reads the lines that coach.py added since the last poll.
    private func poll() {
        guard let file, let handle = try? FileHandle(forReadingFrom: file) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        // Keep a part line for the next poll.
        guard let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        offset += UInt64(end - data.startIndex + 1)
        for line in data[data.startIndex...end].split(separator: UInt8(ascii: "\n")) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let text = row["text"] as? String else { continue }
            let kind = row["kind"] as? String ?? "note"
            if kind == "status" {
                status = text
            } else {
                notes.insert(Note(id: notes.count, clock: row["clock"] as? String ?? "",
                                  kind: kind, text: text), at: 0)
            }
        }
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.title = "Coach"
            p.level = .floating
            p.sharingType = .none
            p.hidesOnDeactivate = false
            p.isFloatingPanel = true
            p.becomesKeyOnlyIfNeeded = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: CoachView(coach: self))
            if !p.setFrameUsingName("CoachPanel"), let screen = NSScreen.main?.visibleFrame {
                p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 400, y: screen.maxY - 20))
            }
            p.setFrameAutosaveName("CoachPanel")
            panel = p
        }
        panel?.orderFrontRegardless()
    }
}

/// The newest note on top in full white, the two before it dimmed.
struct CoachView: View {
    @ObservedObject var coach: Coach

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(coach.notes.prefix(3).enumerated()), id: \.element.id) { index, note in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(note.clock)  \(note.kind.uppercased())")
                        .font(.caption.monospacedDigit().bold())
                        .foregroundStyle(index == 0 ? Color.orange : Color.white.opacity(0.55))
                    Text(note.text)
                        .font(index == 0 ? .system(size: 15, weight: .medium) : .system(size: 12))
                        .foregroundStyle(index == 0 ? Color.white : Color.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Text(coach.status)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.5))
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black.opacity(0.55))
    }
}
