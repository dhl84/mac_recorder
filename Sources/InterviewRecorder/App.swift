import AppKit
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
    @Published var selected: Session?
    @Published var busy = false
    @Published var message = ""
    @Published var found: [Brief.Boundary] = []
    @Published var askSplit = false

    var shown: [Session] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = query.isEmpty ? sessions : sessions.filter { $0.label.lowercased().contains(query) }
        switch sortBy {
        case .date: return kept.sorted { $0.date > $1.date }
        case .label: return kept.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        case .duration: return kept.sorted { $0.duration > $1.duration }
        }
    }

    func reload() {
        let keep = selected?.url
        sessions = Store.list()
        selected = sessions.first { $0.url == keep }
    }

    /// Runs a slow job off the main thread and puts the reason on screen if it fails.
    private func work(_ first: String, _ job: @escaping () throws -> String) {
        busy = true
        message = first
        Task.detached(priority: .userInitiated) {
            do {
                let done = try job()
                await MainActor.run {
                    self.message = done
                    self.busy = false
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.message = error.localizedDescription
                    self.busy = false
                    self.reload()
                }
            }
        }
    }

    /// Transcribes, then names the call when the user left the field empty.
    func transcribe(_ session: Session) {
        work("Starting whisper…") {
            _ = try Transcribe.run(session) { text in
                Task { @MainActor in self.message = text }
            }
            if let name = try? Brief.title(session), !name.isEmpty {
                return "Transcript written. Named it \"\(name)\"."
            }
            return "Transcript written."
        }
    }

    func summarise(_ session: Session) {
        work("Asking the model for the brief…") {
            try Brief.write(session)
            return "Brief written."
        }
    }

    func rename(_ session: Session) {
        work("Asking the model for a title…") {
            guard let name = try Brief.title(session, force: true) else {
                return "The model gave no usable title."
            }
            return "Named it \"\(name)\"."
        }
    }

    func findSplit(_ session: Session) {
        busy = true
        message = "Looking for a second call…"
        Task.detached(priority: .userInitiated) {
            let rows = (try? Brief.boundaries(session)) ?? []
            await MainActor.run {
                self.found = rows
                self.busy = false
                self.message = rows.isEmpty
                    ? "One call. No spell of quiet on both sides long enough to be a join."
                    : "Found \(rows.count) join\(rows.count == 1 ? "" : "s")."
                self.askSplit = !rows.isEmpty
            }
        }
    }

    /// Cuts the recording, then transcribes and names each part. The original stays.
    func applySplit(_ session: Session) {
        work("Cutting the tracks…") {
            let parts = try Brief.applySplit(session)
            for url in parts {
                let part = Session(url: url, label: "", date: session.date, duration: 0)
                _ = try? Transcribe.run(part) { text in
                    Task { @MainActor in self.message = "\(url.lastPathComponent): \(text)" }
                }
                _ = try? Brief.title(part)
            }
            return "Split into \(parts.count) calls. The original folder stays."
        }
    }

    func addToDataset(_ session: Session, folder: String) {
        do {
            let file = try Transcribe.addToDataset(session, folder: folder)
            message = "Added to \(file.deletingLastPathComponent().lastPathComponent)."
        } catch {
            message = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @StateObject private var library = Library()
    @State private var label = ""
    @State private var datasetFolder = ""
    @State private var pane: Pane = .brief

    var body: some View {
        NavigationSplitView {
            list
        } detail: {
            detail
        }
        .toolbar { ToolbarItem(placement: .principal) { recordBar } }
        .frame(minWidth: 940, minHeight: 560)
        .onAppear { library.reload() }
        .alert("Split this recording?", isPresented: $library.askSplit) {
            Button("Split") { if let s = library.selected { library.applySplit(s) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(library.found.map(\.describe).joined(separator: "\n")
                 + "\n\nThe original folder stays as it is.")
        }
    }

    private var recordBar: some View {
        HStack(spacing: 10) {
            TextField("Company and role, or leave it empty", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .disabled(recorder.running)
            Button(recorder.running ? "Stop" : "Record") {
                Task {
                    if recorder.running {
                        await recorder.stop()
                        label = ""
                        library.reload()
                    } else {
                        await recorder.start(label: label)
                    }
                }
            }
            .keyboardShortcut("r")
            .tint(recorder.running ? .red : .accentColor)
            if recorder.running {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text(Store.clock(recorder.elapsed)).monospacedDigit()
            }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            Picker("", selection: $library.sortBy) {
                ForEach(SortBy.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            List(library.shown, selection: $library.selected) { session in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(session.label.isEmpty ? session.url.lastPathComponent : session.label)
                            .fontWeight(.medium)
                        Spacer()
                        if session.hasBrief { Image(systemName: "doc.text") }
                        if session.hasTranscript { Image(systemName: "text.alignleft") }
                    }
                    .foregroundStyle(.secondary)
                    Text("\(session.date.formatted(date: .abbreviated, time: .shortened)) · \(Store.clock(session.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(session)
            }
            .searchable(text: $library.search, placement: .sidebar, prompt: "Filter by name")
        }
        .frame(minWidth: 280)
    }

    @ViewBuilder
    private var detail: some View {
        if let session = library.selected {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.label.isEmpty ? session.url.lastPathComponent : session.label)
                    .font(.title2)
                Text("\(session.date.formatted()) · \(Store.clock(session.duration)) · \(String(format: "%.1f", session.sizeMB)) MB")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(session.hasTranscript ? "Transcribe again" : "Transcribe") {
                        library.transcribe(session)
                    }
                    Button("Summarise") { library.summarise(session) }
                        .disabled(!session.hasTranscript)
                    Button("Rename") { library.rename(session) }
                        .disabled(!session.hasTranscript)
                    Button("Split calls") { library.findSplit(session) }
                    if library.busy { ProgressView().controlSize(.small) }
                }
                .disabled(library.busy)

                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([session.url])
                    }
                    Button("Delete") {
                        Store.delete(session)
                        library.reload()
                    }
                    Spacer()
                    TextField("Application folder", text: $datasetFolder)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                    Menu("Pick") {
                        ForEach(Transcribe.datasetFolders(), id: \.self) { name in
                            Button(name) { datasetFolder = name }
                        }
                    }
                    .frame(width: 70)
                    Button("Add to dataset") { library.addToDataset(session, folder: datasetFolder) }
                        .disabled(!session.hasTranscript)
                }

                Picker("", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                ScrollView {
                    Text(text(session))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(library.message.isEmpty ? recorder.status : library.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .onChange(of: library.selected) { _, new in
                datasetFolder = Store.slug(new?.label ?? "")
            }
        } else {
            VStack(spacing: 8) {
                Text("Name the call, then press Record.").font(.title3)
                Text(recorder.status.isEmpty
                     ? "Leave the name empty and the model writes one from the transcript. If you stay on the line into a second call, press Split calls afterwards."
                     : recorder.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            .padding()
        }
    }

    private func text(_ session: Session) -> String {
        let file = pane == .brief ? session.brief : session.transcript
        if let body = try? String(contentsOf: file, encoding: .utf8) { return body }
        return pane == .brief
            ? "No brief yet. Transcribe the call, then press Summarise."
            : "No transcript yet. Press Transcribe to run whisper on both tracks."
    }
}

@main
struct InterviewRecorderApp: App {
    init() { SelfTest.runIfAsked() }

    var body: some Scene {
        WindowGroup("Interview Recorder") {
            ContentView()
        }
        .windowToolbarStyle(.unified)
    }
}
