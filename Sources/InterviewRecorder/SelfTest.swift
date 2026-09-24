import AVFoundation
import AppKit
import ScreenCaptureKit

/// One runnable check for the parts that can break quietly: the SRT parser, the
/// turn merge and the folder names. Run it with:
///     "Interview Recorder.app/Contents/MacOS/InterviewRecorder" --self-test
enum SelfTest {
    private static func check(_ ok: Bool, _ why: String = "") {
        if !ok {
            FileHandle.standardError.write(Data("self-test FAILED: \(why)\n".utf8))
            exit(1)
        }
    }

    /// Transcribes one session folder from the command line, for a batch or for a
    /// check without the window.
    static func transcribeIfAsked() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--transcribe"), flag + 1 < args.count else { return }
        let url = URL(fileURLWithPath: (args[flag + 1] as NSString).expandingTildeInPath)
        let all = Store.list()
        let session = all.first { $0.url.standardizedFileURL == url.standardizedFileURL }
            ?? Session(url: url, label: url.lastPathComponent, date: Date(), duration: 0)
        do {
            let out = try Transcribe.run(session) { print($0) }
            print("wrote \(out.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func runIfAsked() {
        transcribeIfAsked()
        guard CommandLine.arguments.contains("--self-test") else { return }

        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        Tell me about the reconciliation work.

        2
        00:00:04,000 --> 00:00:05,000
        [BLANK_AUDIO]

        3
        00:01:02,250 --> 00:01:04,000
        It matched nine years of invoices
        to the ledger.
        """

        let lines = Transcribe.parse(srt, speaker: "Them")
        check(lines.count == 2, "a blank block must not become a line, got \(lines.count)")
        check(lines[0].start == 1.0, "start seconds wrong: \(lines[0].start)")
        check(lines[1].start == 62.25, "a minute and a fraction must parse: \(lines[1].start)")
        check(lines[1].text == "It matched nine years of invoices to the ledger.",
               "a two-row block must join with a space: \(lines[1].text)")
        check(lines[0].speaker == "Them")

        // A block without its index row still parses, because some SRT writers omit it.
        let bare = Transcribe.parse("00:00:10,000 --> 00:00:11,000\nYes.", speaker: "Me")
        check(bare.count == 1 && bare[0].start == 10.0, "a block with no index row must parse")

        // The merge must interleave by time and open a new heading only on a change
        // of speaker, so two turns give two headings and three lines give one of them.
        let merged = [
            Transcribe.Line(start: 0, speaker: "Me", text: "Hello."),
            Transcribe.Line(start: 1, speaker: "Them", text: "Hello back."),
            Transcribe.Line(start: 2, speaker: "Them", text: "Shall we start?"),
        ]
        let session = Session(url: URL(fileURLWithPath: "/tmp/x"), label: "Test",
                              date: Date(timeIntervalSince1970: 0), duration: 90)
        let text = Transcribe.render(session, lines: merged)
        check(text.components(separatedBy: "## ").count - 1 == 2,
               "two speakers in a row must share one heading")
        check(text.contains("Hello back. Shall we start?"),
               "the neighbour lines of one speaker must join")
        check(text.contains("Length 00:01:30"), "the length must show as a clock")

        check(Store.slug("Acme — Finance Lead!") == "acme-finance-lead",
               "slug wrong: \(Store.slug("Acme — Finance Lead!"))")
        check(Store.folderName(label: "Acme Ltd", date: Date(timeIntervalSince1970: 1_600_000_000))
                .hasSuffix("-acme-ltd"))
        check(Store.clock(3_661) == "01:01:01", "clock wrong: \(Store.clock(3_661))")

        // The dataset copy touches a real folder, so prove it on a temporary one.
        // Point INTERVIEW_DATASET at a scratch directory before you run this.
        if ProcessInfo.processInfo.environment["INTERVIEW_DATASET"] != nil {
            let fm = FileManager.default
            let box = fm.temporaryDirectory.appendingPathComponent("ir-selftest-\(UUID().uuidString)")
            try? fm.createDirectory(at: box, withIntermediateDirectories: true)
            try? "# transcript\n".write(to: box.appendingPathComponent("transcript.md"),
                                       atomically: true, encoding: .utf8)
            let one = Session(url: box, label: "Acme Ltd Analyst",
                              date: Date(timeIntervalSince1970: 1_600_000_000), duration: 12)
            do {
                let copied = try Transcribe.addToDataset(one, folder: "acme-ltd-analyst")
                check(fm.fileExists(atPath: copied.path), "the transcript copy is missing")
                let index = Store.dataset.appendingPathComponent("interviews.jsonl")
                let rows = (try? String(contentsOf: index, encoding: .utf8))?
                    .split(separator: "\n").count ?? 0
                check(rows >= 1, "the index holds no row")
                check(Transcribe.datasetFolders().contains("acme-ltd-analyst"),
                      "the new folder does not list")
            } catch {
                check(false, "addToDataset threw: \(error.localizedDescription)")
            }
            try? fm.removeItem(at: box)
        }

        // A track that gets its first buffer 3 seconds late must hold 3 seconds of
        // silence before it, or the two tracks lose their common clock.
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("ir-pad-\(UUID().uuidString).wav")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let tenth = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
            tenth.frameLength = 4_800
            do {
                let track = try Track(url: wav, started: Date().addingTimeInterval(-3))
                track.write(tenth)
            }
            let seconds = Double(try AVAudioFile(forReading: wav).length) / 16_000
            check(abs(seconds - 3.0) < 0.2, "a late track must pad to the clock, got \(seconds) s")
        } catch {
            check(false, "the padding check threw: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: wav)

        // Playback must run both tracks and report its place. The files hold silence,
        // so the check plays nothing that you can hear.
        let box = FileManager.default.temporaryDirectory.appendingPathComponent("ir-play-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
            let blip = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
            blip.frameLength = 160
            for name in ["mic.wav", "system.wav"] {
                try Track(url: box.appendingPathComponent(name), started: Date().addingTimeInterval(-2)).write(blip)
            }
            let player = Player()
            player.load(Session(url: box, label: "x", date: Date(), duration: 2))
            check(abs(player.length - 2) < 0.2, "playback length wrong: \(player.length)")
            player.play()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            check(player.playing && player.position > 0.4, "playback did not move: \(player.position)")
            player.pause()
            check(!player.playing, "pause did not stop playback")
        } catch {
            check(false, "the playback check threw: \(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: box)

        print("self-test passed")
        exit(0)
    }
}

/// Saves a PNG of the app's own window and quits. It uses the app's own screen
/// recording permission, so start it with `open -n` to make the app responsible:
///     open -n "Interview Recorder.app" --args --snapshot /abs/out.png [--recording]
enum Snapshot {
    static func takeIfAsked(_ recorder: Recorder) {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--snapshot"), flag + 1 < args.count else { return }
        if args.contains("--recording") { recorder.preview() }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: {
                    $0.owningApplication?.processID == getpid() && $0.frame.width > 300
                }) else { exit(2) }
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * 2)
                config.height = Int(window.frame.height * 2)
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: args[flag + 1]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
    }
}
