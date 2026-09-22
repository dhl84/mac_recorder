import SwiftUI

enum SortBy: String, CaseIterable, Identifiable {
    case date = "Newest"
    case label = "Name"
    case duration = "Longest"
    var id: String { rawValue }
}

enum Pane: String, CaseIterable, Identifiable {
    case brief = "Brief"
    case transcript = "Transcript"
    var id: String { rawValue }
}

@MainActor
final class Library: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var sortBy: SortBy = .date
    @Published var search = ""
    @Published var busy = false
    @Published var message = ""

    var shown: [Session] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = query.isEmpty ? sessions : sessions.filter {
            $0.label.lowercased().contains(query) || $0.url.lastPathComponent.contains(query)
        }
        switch sortBy {
        case .date: return kept.sorted { $0.date > $1.date }
        case .label: return kept.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        case .duration: return kept.sorted { $0.duration > $1.duration }
        }
    }

    func reload() { sessions = Store.list() }

    func run(_ first: String, _ job: @escaping () async throws -> String) {
        busy = true
        message = first
        Task {
            do { message = try await job() } catch { message = error.localizedDescription }
            busy = false
            reload()
        }
    }

    /// Transcribes, then names the call when the user left the field empty.
    func transcribe(_ session: Session) {
        run("Starting…") {
            _ = try await Transcribe.run(session) { text in
                Task { @MainActor in self.message = text }
            }
            // try? flattens the optional, so `name` is the title itself.
            if session.label.isEmpty, let name = try? await Brief.title(session) {
                return "Transcript written. Named it \"\(name)\"."
            }
            return "Transcript written."
        }
    }

    func summarise(_ session: Session) {
        run("Asking the on-device model…") {
            try await Brief.write(session) { text in
                Task { @MainActor in self.message = text }
            }
            return "Brief written."
        }
    }

    func rename(_ session: Session) {
        run("Asking for a title…") {
            guard let name = try await Brief.title(session) else {
                return "The model gave no usable title."
            }
            return "Named it \"\(name)\"."
        }
    }
}

// MARK: - root

struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @StateObject private var library = Library()
    @State private var label = ""
    @State private var showTest = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                recordCard
                Divider()
                list
            }
            .navigationTitle("Call Notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $library.sortBy) {
                            ForEach(SortBy.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Button("Self test") { showTest = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .searchable(text: $library.search, prompt: "Filter by name")
            .sheet(isPresented: $showTest) { SelfTestView() }
        }
        .onAppear { library.reload() }
        .task {
            if let folder = Headless.demoFolder { await Headless.transcribeDemo(folder) }
        }
    }

    private var recordCard: some View {
        VStack(spacing: 12) {
            TextField("Company and role, or leave it empty", text: $label)
                .textFieldStyle(.roundedBorder)
                .disabled(recorder.running)

            if recorder.running {
                // A level bar, so a silent microphone shows itself during the call
                // and not an hour later.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.red)
                            .frame(width: max(4, geo.size.width * recorder.level))
                    }
                }
                .frame(height: 8)
                Text(Store.clock(recorder.elapsed))
                    .font(.system(.title2, design: .monospaced))
                    .monospacedDigit()
            }

            Button {
                Task {
                    if recorder.running {
                        await recorder.stop()
                        label = ""
                        library.reload()
                    } else {
                        await recorder.start(label: label)
                    }
                }
            } label: {
                Label(recorder.running ? "Stop" : "Record",
                      systemImage: recorder.running ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(recorder.running ? .red : .accentColor)

            Text(library.message.isEmpty ? recorder.status : library.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }

    private var list: some View {
        List {
            ForEach(library.shown) { session in
                NavigationLink {
                    DetailView(session: session, library: library)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.label.isEmpty ? session.url.lastPathComponent : session.label)
                            .fontWeight(.medium)
                        HStack(spacing: 6) {
                            Text(session.date.formatted(date: .abbreviated, time: .shortened))
                            Text("·")
                            Text(Store.clock(session.duration))
                            if session.hasTranscript { Image(systemName: "text.alignleft") }
                            if session.hasBrief { Image(systemName: "doc.text") }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { library.shown[$0] }.forEach(Store.delete)
                library.reload()
            }
        }
        .listStyle(.plain)
        .overlay {
            if library.shown.isEmpty {
                ContentUnavailableView("No calls yet", systemImage: "waveform",
                                       description: Text("Press Record. On a call, put it on speakerphone so the microphone hears both sides."))
            }
        }
    }
}

// MARK: - detail

struct DetailView: View {
    let session: Session
    @ObservedObject var library: Library
    @State private var pane: Pane = .brief
    @State private var cuts: [Double] = []
    @State private var askSplit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(session.date.formatted()) · \(Store.clock(session.duration)) · \(String(format: "%.1f", session.sizeMB)) MB")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button(session.hasTranscript ? "Transcribe again" : "Transcribe") {
                        library.transcribe(session)
                    }
                    Button("Summarise") { library.summarise(session) }
                        .disabled(!session.hasTranscript)
                    Button("Rename") { library.rename(session) }
                        .disabled(!session.hasTranscript)
                    Button("Split calls") { findSplit() }
                    ShareLink(item: session.hasBrief ? session.brief : session.transcript) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(!session.hasTranscript)
                }
                .buttonStyle(.bordered)
            }
            .disabled(library.busy)

            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if library.busy { ProgressView().controlSize(.small) }
                Text(library.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle(session.label.isEmpty ? session.url.lastPathComponent : session.label)
        .navigationBarTitleDisplayMode(.inline)
        .alert("Split this recording?", isPresented: $askSplit) {
            Button("Split") { applySplit() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cuts.map { "Cut at \(Store.clock($0))." }.joined(separator: "\n")
                 + "\n\nOne microphone track gives weaker evidence than the Mac version, so check the times. The original stays.")
        }
    }

    private var text: String {
        let file = pane == .brief ? session.brief : session.transcript
        if let body = try? String(contentsOf: file, encoding: .utf8) { return body }
        return pane == .brief
            ? "No brief yet. Transcribe the call, then press Summarise."
            : "No transcript yet. Press Transcribe."
    }

    private func findSplit() {
        library.run("Looking for a second call…") {
            let levels = try Split.levels(session.audio)
            let found = Split.quiet(levels)
            await MainActor.run {
                cuts = found
                askSplit = !found.isEmpty
            }
            return found.isEmpty
                ? "One call. No silence long enough to be a join."
                : "Found \(found.count) candidate\(found.count == 1 ? "" : "s")."
        }
    }

    private func applySplit() {
        let at = cuts
        library.run("Cutting the recording…") {
            let parts = try Split.apply(session, at: at)
            for url in parts {
                let meta = Store.readMeta(url)
                let part = Session(url: url, label: "",
                                   date: session.date,
                                   duration: meta["duration"] as? TimeInterval ?? 0)
                _ = try? await Transcribe.run(part) { _ in }
                _ = try? await Brief.title(part)
            }
            return "Split into \(parts.count) calls. The original stays."
        }
    }
}

@main
struct CallNotesApp: App {
    init() { Headless.runIfAsked() }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
