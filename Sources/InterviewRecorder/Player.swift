import AVFoundation

/// Plays both tracks of one session together, so you hear both sides of the call.
/// Each track has its own player, and both start at the same device time.
final class Player: ObservableObject {
    @Published private(set) var playing = false
    @Published var position: TimeInterval = 0
    @Published private(set) var length: TimeInterval = 0

    private var players: [AVAudioPlayer] = []
    private var loaded: URL?
    private var timer: Timer?
    private var resumeAfterScrub = false

    func load(_ session: Session?) {
        guard session?.url != loaded else { return }
        pause()
        loaded = session?.url
        players = ["mic.wav", "system.wav"].compactMap { name in
            guard let url = session?.url.appendingPathComponent(name) else { return nil }
            return try? AVAudioPlayer(contentsOf: url)
        }
        players.forEach { $0.prepareToPlay() }
        length = players.map(\.duration).max() ?? 0
        position = 0
    }

    func toggle() { playing ? pause() : play() }

    func play() {
        guard let first = players.first else { return }
        if position >= length - 0.1 { position = 0 }
        let start = first.deviceCurrentTime + 0.05
        for player in players {
            player.currentTime = min(position, player.duration)
            player.play(atTime: start)
        }
        playing = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    }

    func pause() {
        timer?.invalidate()
        timer = nil
        if playing { position = players.map(\.currentTime).max() ?? position }
        players.forEach { $0.pause() }
        playing = false
    }

    /// The slider moves `position` while you drag. Playback stops for the drag and
    /// continues from the new place.
    func scrub(editing: Bool) {
        if editing {
            resumeAfterScrub = playing
            pause()
        } else if resumeAfterScrub {
            play()
        }
    }

    private func tick() {
        position = players.map(\.currentTime).max() ?? 0
        if !players.contains(where: \.isPlaying) { pause(); position = 0 }
    }
}
