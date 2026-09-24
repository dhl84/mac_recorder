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
    private let started: Date
    private var written: AVAudioFramePosition = 0
    private let lock = NSLock()
    private var lastBuffer = Date.distantPast
    private var lastLevel: Float = 0

    /// When the last buffer arrived and how loud it was (0 to 1), for the live display.
    var health: (last: Date, level: Float) {
        lock.lock(); defer { lock.unlock() }
        return (lastBuffer, lastLevel)
    }

    init(url: URL, started: Date = Date()) throws {
        self.url = url
        self.started = started
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
        guard err == nil, out.frameLength > 0 else { return }
        let samples = UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count))
        // ponytail: a 60 dB window is enough to tell speech from silence.
        let level = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 60) / 60))
        lock.lock(); lastBuffer = Date(); lastLevel = level; lock.unlock()
        padToClock(before: out.frameLength)
        try? file.write(from: out)
        written += AVAudioFramePosition(out.frameLength)
    }

    /// A gap (a device change, a capture restart) gives no samples. Silence fills
    /// it, so both tracks keep the wall clock and the transcript keeps the turn order.
    private func padToClock(before frames: AVAudioFrameCount) {
        let due = AVAudioFramePosition(Date().timeIntervalSince(started) * target.sampleRate)
            - AVAudioFramePosition(frames)
        var missing = due - written
        guard missing > AVAudioFramePosition(target.sampleRate / 2) else { return }
        while missing > 0 {
            let count = AVAudioFrameCount(min(missing, 16_000))
            guard let silence = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: count) else { return }
            silence.frameLength = count
            memset(silence.floatChannelData![0], 0, Int(count) * MemoryLayout<Float>.size)
            try? file.write(from: silence)
            written += AVAudioFramePosition(count)
            missing -= AVAudioFramePosition(count)
        }
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
    /// A track is live while its buffers keep arriving. A dead track is the failure
    /// that ended a real call's recording while the clock kept running.
    @Published private(set) var micLive = false
    @Published private(set) var sysLive = false
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var sysLevel: Float = 0

    private let engine = AVAudioEngine()
    private var stream: SCStream?
    private var mic: Track?
    private var sys: Track?
    private var timer: Timer?
    private var started = Date()
    private var folder: URL?
    private var label = ""
    private let queue = DispatchQueue(label: "recorder.audio")
    private var deviceObserver: NSObjectProtocol?

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
            let now = Date()
            mic = try Track(url: dir.appendingPathComponent("mic.wav"), started: now)
            sys = try Track(url: dir.appendingPathComponent("system.wav"), started: now)

            try startMic()
            // A headset that joins a call switches profile, and the engine stops
            // with no error. Without this the microphone track ends at that moment.
            deviceObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
            ) { [weak self] _ in self?.restartMic() }

            try await startSystemAudio()

            started = Date()
            elapsed = 0
            running = true
            say("Recording. The microphone and the system output both write to \(dir.lastPathComponent).")
            // start() runs off the main thread, where a scheduled timer never fires.
            // The main run loop in common mode also ticks while a menu is open.
            let clock = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(clock, forMode: .common)
            timer = clock
        } catch {
            await stop()
            say("Start failed: \(error.localizedDescription)")
        }
    }

    private func startMic() throws {
        guard let micTrack = mic else { return }
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw NSError(domain: "InterviewRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "The input device reports no sample rate. Select a microphone in Sound settings."])
        }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { buffer, _ in
            micTrack.write(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// The new device can need a moment, so a failed restart tries again.
    private func restartMic(attempt: Int = 1) {
        guard running else { return }
        engine.stop()
        do {
            try startMic()
            say("The audio device changed. The microphone recording continues.")
        } catch {
            guard attempt < 10 else {
                return say("The microphone stopped after a device change: \(error.localizedDescription). Stop and start again.")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.restartMic(attempt: attempt + 1) }
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

    /// Fake live state for `--snapshot --recording`, so the layout can be checked
    /// without a real recording.
    func preview() {
        running = true
        elapsed = 754
        micLive = true
        micLevel = 0.6
        sysLive = false
    }

    private func tick() {
        elapsed = Date().timeIntervalSince(started)
        let now = Date()
        if let m = mic?.health { micLive = now.timeIntervalSince(m.last) < 3; micLevel = micLive ? m.level : 0 }
        if let s = sys?.health { sysLive = now.timeIntervalSince(s.last) < 3; sysLevel = sysLive ? s.level : 0 }
    }

    // MARK: stop

    @discardableResult
    func stop() async -> URL? {
        timer?.invalidate()
        timer = nil
        if let deviceObserver { NotificationCenter.default.removeObserver(deviceObserver) }
        deviceObserver = nil
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
        micLive = false
        sysLive = false
        micLevel = 0
        sysLevel = 0
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

    /// The capture stops when the display sleeps or changes. It restarts while
    /// the recording runs, so a locked screen does not end the other side's track.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async {
            guard self.running, self.stream === stream else { return }
            self.stream = nil
            self.say("The system audio capture stopped: \(error.localizedDescription). Restarting it.")
            Task { await self.restartSystemAudio() }
        }
    }

    private func restartSystemAudio() async {
        while running && stream == nil {
            do {
                try await startSystemAudio()
                say("The system audio capture restarted. The recording continues.")
            } catch {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func say(_ text: String) {
        DispatchQueue.main.async { self.status = text }
    }
}
