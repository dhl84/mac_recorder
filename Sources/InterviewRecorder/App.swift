import AppKit
import SwiftUI

enum SortBy: String, CaseIterable, Identifiable {
    case date = "Newest"
    case label = "Name"
    case duration = "Longest"
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
        sessions = Store.list()
        if let selected, !sessions.contains(where: { $0.url == selected.url }) { self.selected = nil }
        if let current = selected { self.selected = sessions.first { $0.url == current.url } }
    }

    func transcribe(_ session: Session) {
        busy = true
        message = "Starting whisper…"
        Task.detached(priority: .userInitiated) {
            do {
                _ = try Transcribe.run(session) { text in
                    Task { @MainActor in self.message = text }
                }
                await MainActor.run {
                    self.message = "Transcript written."
                    self.busy = false
                    self.reload()
                }
            } catch {
                await MainActor.run {
                    self.message = error.localizedDescription
                    self.busy = false
                }
            }
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

    var body: some View {
        NavigationSplitView {
            list
        } detail: {
            detail
        }
        .toolbar { ToolbarItem(placement: .principal) { recordBar } }
        .frame(minWidth: 880, minHeight: 520)
        .onAppear { library.reload() }
    }

    // MARK: record

    private var recordBar: some View {
        HStack(spacing: 10) {
            TextField("Company and role", text: $label)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
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

    // MARK: list

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $library.sortBy) {
                    ForEach(SortBy.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(8)
            List(library.shown, selection: $library.selected) { session in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(session.label).fontWeight(.medium)
                        Spacer()
                        if session.hasTranscript {
                            Image(systemName: "text.alignleft").foregroundStyle(.secondary)
                        }
                    }
                    Text("\(session.date.formatted(date: .abbreviated, time: .shortened)) · \(Store.clock(session.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(session)
            }
            .searchable(text: $library.search, placement: .sidebar, prompt: "Filter by name")
        }
        .frame(minWidth: 260)
    }

    // MARK: detail

    @ViewBuilder
    private var detail: some View {
        if let session = library.selected {
            VStack(alignment: .leading, spacing: 12) {
                Text(session.label).font(.title2)
                Text("\(session.date.formatted()) · \(Store.clock(session.duration)) · \(String(format: "%.1f", session.sizeMB)) MB")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(session.hasTranscript ? "Transcribe again" : "Transcribe") {
                        library.transcribe(session)
                    }
                    .disabled(library.busy)
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([session.url])
                    }
                    Button("Delete") {
                        Store.delete(session)
                        library.reload()
                    }
                    if library.busy { ProgressView().controlSize(.small) }
                }

                HStack {
                    TextField("Application folder", text: $datasetFolder)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                    Menu("Pick") {
                        ForEach(Transcribe.datasetFolders(), id: \.self) { name in
                            Button(name) { datasetFolder = name }
                        }
                    }
                    .frame(width: 80)
                    Button("Add to dataset") {
                        library.addToDataset(session, folder: datasetFolder)
                    }
                    .disabled(!session.hasTranscript)
                }

                Divider()
                ScrollView {
                    Text(transcriptText(session))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                Text(library.message.isEmpty ? recorder.status : library.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .onAppear { if datasetFolder.isEmpty { datasetFolder = Store.slug(session.label) } }
        } else {
            VStack(spacing: 8) {
                Text("Name the call, then press Record.").font(.title3)
                Text(recorder.status.isEmpty
                     ? "The microphone and the system output both record. Every app that plays the far end through the speakers is covered."
                     : recorder.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding()
        }
    }

    private func transcriptText(_ session: Session) -> String {
        (try? String(contentsOf: session.transcript, encoding: .utf8))
            ?? "No transcript yet. Press Transcribe to run whisper on both tracks."
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
