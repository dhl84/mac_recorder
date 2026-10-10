import AVFoundation
import SwiftUI

/// Practice mode: a question for the stage you practise, your recorded answer, and
/// an evaluation. practice.py runs the steps, and your own practice pack supplies
/// the questions and the marking. This file records the microphone and draws the window.
@MainActor
final class Practice: ObservableObject {
    struct Stage: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published var stages: [Stage] = []
    @Published var question = ""
    @Published var target: Double = 0
    @Published var evaluation = ""
    @Published var message = ""
    @Published var busy = false
    @Published private(set) var recording = false
    @Published private(set) var elapsed: TimeInterval = 0

    // The window keeps these settings for the next launch.
    @Published var stage = UserDefaults.standard.string(forKey: "practiceStage") ?? "" {
        didSet { UserDefaults.standard.set(stage, forKey: "practiceStage") }
    }
    @Published var engineName = UserDefaults.standard.string(forKey: "practiceEngine") ?? "claude" {
        didSet { UserDefaults.standard.set(engineName, forKey: "practiceEngine") }
    }
    @Published var pack = UserDefaults.standard.string(forKey: "practicePack") ?? "~/practice-pack" {
        didSet { UserDefaults.standard.set(pack, forKey: "practicePack") }
    }

    private var folder: URL?
    private let engine = AVAudioEngine()
    private var track: Track?
    private var started = Date()
    private var timer: Timer?

    static var script: String {
        if let inBundle = Bundle.main.url(forResource: "practice", withExtension: "py") { return inBundle.path }
        return (Brief.script as NSString).deletingLastPathComponent + "/practice.py"
    }

    /// Finder starts the app with no shell variables, so the window settings go to
    /// the script as variables. A variable that the shell already set wins.
    private func call(_ args: [String]) async -> [String: Any] {
        let shell = ProcessInfo.processInfo.environment
        var env: [String] = []
        if shell["PRACTICE_PACK"] == nil { env.append("PRACTICE_PACK=\((pack as NSString).expandingTildeInPath)") }
        if shell["PRACTICE_ENGINE"] == nil { env.append("PRACTICE_ENGINE=\(engineName)") }
        // The local model has no control in the window: `defaults write ... practiceLocalModel <name>`.
        if shell["PRACTICE_MODEL"] == nil, engineName == "ollama",
           let model = UserDefaults.standard.string(forKey: "practiceLocalModel"), !model.isEmpty {
            env.append("PRACTICE_MODEL=\(model)")
        }
        let argv = env + [Brief.python, Practice.script] + args
        let result = await Task.detached { Transcribe.shell("/usr/bin/env", argv) }.value
        guard let data = result.out.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["error": String((result.err.isEmpty ? result.out : result.err).suffix(400))]
        }
        return top
    }

    func loadStages() async {
        let out = await call(["stages"])
        if let error = out["error"] as? String { message = error; stages = []; return }
        stages = (out["stages"] as? [[String: Any]] ?? []).compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return Stage(id: id, name: row["name"] as? String ?? id)
        }
        if !stages.contains(where: { $0.id == stage }) { stage = stages.first?.id ?? "" }
        message = stages.isEmpty ? "The pack has no stages." : ""
    }

    func next() async {
        busy = true
        defer { busy = false }
        let out = await call(["question", stage])
        if let error = out["error"] as? String { message = error; return }
        question = out["text"] as? String ?? ""
        target = out["seconds"] as? Double ?? 0
        folder = (out["folder"] as? String).map { URL(fileURLWithPath: $0) }
        evaluation = ""
        message = "Press Answer, give your answer aloud, then press Stop."
    }

    func startAnswer() async {
        guard let folder, !recording else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            message = "No microphone permission. Open System Settings, Privacy and Security, Microphone."
            return
        }
        do {
            let now = Date()
            let t = try Track(url: folder.appendingPathComponent("answer.wav"), started: now)
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4_096, format: input.inputFormat(forBus: 0)) { buffer, _ in
                t.write(buffer)
            }
            engine.prepare()
            try engine.start()
            track = t
            started = now
            elapsed = 0
            recording = true
            message = "Recording your answer."
            let clock = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            RunLoop.main.add(clock, forMode: .common)
            timer = clock
        } catch {
            message = "The microphone did not start: \(error.localizedDescription)"
        }
    }

    private func tick() { elapsed = Date().timeIntervalSince(started) }

    func stopAnswer() async {
        guard recording, let folder else { return }
        timer?.invalidate()
        timer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        track = nil  // closes the file
        recording = false
        await evaluate(folder: folder, seconds: Date().timeIntervalSince(started))
    }

    /// Also runs again on the same answer, for example with another engine.
    func evaluate(folder: URL? = nil, seconds: TimeInterval? = nil) async {
        guard let folder = folder ?? self.folder else { return }
        busy = true
        defer { busy = false }
        message = "Transcribing your answer and asking \(engineName) for the evaluation…"
        var args = ["evaluate", folder.path]
        if let seconds { args += ["--seconds", String(Int(seconds))] }
        let out = await call(args)
        if let error = out["error"] as? String { message = error; return }
        if let file = out["file"] as? String {
            evaluation = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        }
        message = (out["score"] as? Int).map { "Score \($0) of 10. Press New question for the next one." }
            ?? "Evaluation written."
    }

    var hasAnswer: Bool {
        folder.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("answer.wav").path) } ?? false
    }

    /// Fake state for `--practice-snapshot`, so the layout can be checked.
    func preview() {
        stages = [Stage(id: "screen", name: "Acme: Round 2, case interview")]
        stage = "screen"
        question = "Sign-ups fell 20% last week. How do you find out why?"
        target = 120
        evaluation = "Score: 6/10\n\n## What worked\n- You split the drop by channel first.\n\n## Fix next time\n- Say the answer first, then the steps."
        message = "Score 6 of 10. Press New question for the next one."
    }
}

struct PracticeView: View {
    @ObservedObject var recorder: Recorder
    @StateObject private var practice = Practice()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Stage", selection: $practice.stage) {
                    ForEach(practice.stages) { Text($0.name).tag($0.id) }
                }
                .frame(minWidth: 320)
                Picker("Engine", selection: $practice.engineName) {
                    Text("Claude").tag("claude")
                    Text("Codex").tag("codex")
                    Text("Local").tag("ollama")
                }
                .frame(width: 170)
                .help("Claude and Codex use your subscription. Local uses Ollama on this Mac.")
                Spacer()
                Button("New question") { Task { await practice.next() } }
                    .disabled(practice.stage.isEmpty || practice.recording || practice.busy)
            }

            Text(practice.question.isEmpty ? "Pick a stage, then press New question." : practice.question)
                .font(.title2.weight(.medium))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(practice.recording ? "Stop" : "Answer") {
                    Task { practice.recording ? await practice.stopAnswer() : await practice.startAnswer() }
                }
                .keyboardShortcut(.space, modifiers: [])
                .tint(practice.recording ? .red : .accentColor)
                .buttonStyle(.borderedProminent)
                .disabled(practice.question.isEmpty || practice.busy || recorder.running)
                if practice.recording || practice.elapsed > 0 {
                    Text(Store.clock(practice.elapsed)
                         + (practice.target > 0 ? " of \(Store.clock(practice.target))" : ""))
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(practice.target > 0 && practice.elapsed > practice.target ? .red : .secondary)
                }
                Button("Evaluate again") { Task { await practice.evaluate() } }
                    .disabled(!practice.hasAnswer || practice.recording || practice.busy)
                if practice.busy { ProgressView().controlSize(.small) }
            }

            ScrollView {
                Text(rendered(practice.evaluation))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                Text(recorder.running ? "A call is recording. Practice waits until it stops." : practice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Text("Pack: \(practice.pack)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Button("Change") { pickPack() }
                    .controlSize(.small)
            }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 480)
        .task {
            if CommandLine.arguments.contains("--practice-snapshot") { practice.preview() } else { await practice.loadStages() }
        }
    }

    /// Inline Markdown keeps the line breaks. A heading line becomes bold text.
    private func rendered(_ markdown: String) -> AttributedString {
        let text = markdown.replacingOccurrences(of: #"(?m)^#{1,3} (.+)$"#, with: "**$1**",
                                                 options: .regularExpression)
        return (try? AttributedString(markdown: text, options:
                    .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(markdown)
    }

    private func pickPack() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: (practice.pack as NSString).expandingTildeInPath)
        panel.prompt = "Use this pack"
        panel.message = "Pick the folder that holds pack.py."
        if panel.runModal() == .OK, let url = panel.url {
            practice.pack = url.path
            Task { await practice.loadStages() }
        }
    }
}
