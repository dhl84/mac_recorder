import AVFoundation
import Combine

/// Records the iPhone microphone to one 16 kHz mono WAV.
///
/// An iPhone gives no app the audio of another app, so there is no second track
/// and no system output track. On speakerphone the microphone picks up both
/// sides of the call in this one track.
final class Recorder: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var running = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0
    @Published var status = ""

    /// 16 kHz mono is what the speech model reads, and one hour takes 110 MB.
    static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var folder: URL?
    private var label = ""
    private var started = Date()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(interrupted(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    func start(label rawLabel: String) async {
        guard !running else { return }
        label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)

        guard await AVAudioApplication.requestRecordPermission() else {
            return say("No microphone permission. Open Settings, Privacy and Security, Microphone.")
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            // .record with the default mode, never .voiceChat. Voice processing runs
            // echo cancellation, which removes the speaker audio. On speakerphone
            // that audio is the other person, which is the half worth keeping.
            try audio.setCategory(.record, mode: .default)
            try audio.setActive(true)

            let dir = Store.root.appendingPathComponent(Store.folderName(label: label, date: Date()))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            folder = dir

            let new = try AVAudioRecorder(url: dir.appendingPathComponent("audio.wav"),
                                          settings: Recorder.settings)
            new.delegate = self
            new.isMeteringEnabled = true
            guard new.record() else {
                return say("The recorder did not start. Another app may hold the microphone.")
            }
            recorder = new
            started = Date()
            elapsed = 0
            running = true
            say(label.isEmpty
                ? "Recording. The model writes a title afterwards."
                : "Recording \(label).")
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                self?.tick()
            }
        } catch {
            say("Start failed: \(error.localizedDescription)")
            await stop()
        }
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // -60 dB is silence and 0 dB is the loudest the input reports.
        let power = Double(recorder.averagePower(forChannel: 0))
        level = max(0, min(1, (power + 55) / 55))
    }

    @discardableResult
    func stop() async -> URL? {
        timer?.invalidate()
        timer = nil
        let seconds = recorder?.currentTime ?? 0
        recorder?.stop()
        recorder = nil
        running = false
        elapsed = 0
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false)
        guard let dir = folder else { return nil }
        folder = nil
        Store.writeMeta(folder: dir, label: label, date: started, duration: seconds)
        say("Stopped after \(Store.clock(seconds)).")
        return dir
    }

    /// An incoming call takes the microphone, so the recording stops and keeps
    /// what it has instead of losing the file.
    @objc private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began, running else { return }
        Task { @MainActor in
            await self.stop()
            self.status = "Something else took the microphone. The recording stopped and is saved."
        }
    }

    private func say(_ text: String) {
        Task { @MainActor in self.status = text }
    }
}
