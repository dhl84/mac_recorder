import AVFoundation
import ScreenCaptureKit

// MARK: - one WAV track

/// Writes one 16 kHz mono WAV file and converts whatever format the source gives.
/// ponytail: convert at capture time, so whisper-cli needs no ffmpeg pass later.
final class Track {
    let url: URL
    private let file: AVAudioFile
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(url: URL) throws {
        self.url = url
        target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: 16_000, channels: 1, interleaved: false)!
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
    }

    /// One converter lives for the whole track. A new converter for each buffer
    /// restarts the resampler and puts a click between the buffers.
    func write(_ input: AVAudioPCMBuffer) {
        if converter == nil || converter!.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: target)
        }
        guard let converter, input.frameLength > 0 else { return }
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1_024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var used = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if used { status.pointee = .noDataNow; return nil }
            used = true
            status.pointee = .haveData
            return input
        }
        if err == nil && out.frameLength > 0 { try? file.write(from: out) }
    }
}

// MARK: - capture

/// Records the microphone and the system output to two separate files.
///
/// Two files, not one mix. The microphone is you and the system output is the
/// other people on the call, so a separate file gives the transcript its
/// speaker labels for free.
final class Recorder: NSObject, ObservableObject, SCStreamOutput, SCStreamDelegate {
    @Published private(set) var running = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var status = ""

    private let engine = AVAudioEngine()
    private var stream: SCStream?
    private var mic: Track?
    private var sys: Track?
    private var timer: Timer?
    private var started = Date()
    private var folder: URL?
    private var label = ""
    private let queue = DispatchQueue(label: "recorder.audio")

    // MARK: start

    func start(label rawLabel: String) async {
        guard !running else { return }
        label = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty { label = "Interview" }

        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            return say("No microphone permission. Open System Settings, Privacy and Security, Microphone.")
        }
        do {
            let dir = Store.root.appendingPathComponent(Store.folderName(label: label, date: Date()))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            folder = dir
            let micTrack = try Track(url: dir.appendingPathComponent("mic.wav"))
            let sysTrack = try Track(url: dir.appendingPathComponent("system.wav"))
            mic = micTrack
            sys = sysTrack

            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                return say("The input device reports no sample rate. Select a microphone in Sound settings.")
            }
            input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
                micTrack.write(buffer)
            }
            engine.prepare()
            try engine.start()

            try await startSystemAudio()

            started = Date()
            elapsed = 0
            running = true
            say("Recording. The microphone and the system output both write to \(dir.lastPathComponent).")
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { self.elapsed = Date().timeIntervalSince(self.started) }
            }
        } catch {
            await stop()
            say("Start failed: \(error.localizedDescription)")
        }
    }

    /// ScreenCaptureKit gives the mixed system output of every other process.
    /// That covers Teams, Meet, Zoom and WhatsApp together, because each of them
    /// plays the far end through the normal output device.
    private func startSystemAudio() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "InterviewRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display to attach the audio capture to."])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // ponytail: ScreenCaptureKit always makes video frames, so ask for the
        // smallest and slowest ones it accepts. We throw them away.
        config.width = 2
        config.height = 2
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    // MARK: stop

    @discardableResult
    func stop() async -> URL? {
        timer?.invalidate()
        timer = nil
        if engine.isRunning || engine.inputNode.numberOfInputs > 0 {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        let seconds = running ? Date().timeIntervalSince(started) : 0
        running = false
        elapsed = 0
        mic = nil
        sys = nil
        guard let dir = folder else { return nil }
        folder = nil
        Store.writeMeta(folder: dir, label: label, date: started, duration: seconds)
        say("Stopped after \(Store.clock(seconds)). Saved to \(dir.lastPathComponent).")
        return dir
    }

    // MARK: delegates

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let sys, buffer.isValid else { return }
        guard let description = buffer.formatDescription?.audioStreamBasicDescription else { return }
        var asbd = description
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }
        try? buffer.withAudioBufferList { list, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer)
            else { return }
            sys.write(pcm)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            self.status = "The system audio capture stopped: \(error.localizedDescription)"
        }
    }

    private func say(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }
}
