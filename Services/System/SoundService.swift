import AppKit
import AVFoundation
import Foundation

/// Audio feedback — recording start/stop + translate start/done.
/// Supports custom user sounds loaded from files.
/// Uses AVAudioPlayer with prepareToPlay() pre-warming to eliminate first-play delay.
final class SoundService {
    private let enabled: () -> Bool
    /// Cache: role → pre-warmed AVAudioPlayer for instant playback
    private var players: [String: AVAudioPlayer] = [:]

    /// Default system sounds
    private static let defaultSounds: [String: String] = [
        "start": "Tink",
        "stop": "Purr",
        "translateStart": "Morse",
        "translateDone": "Glass"
    ]

    init(enabled: @escaping () -> Bool = { AppSettings.shared.soundEnabled }) {
        self.enabled = enabled
        loadSounds()
        NotificationCenter.default.addObserver(forName: .init("ReloadSounds"), object: nil, queue: .main) { [weak self] _ in
            self?.loadSounds()
        }
    }

    func loadSounds() {
        players.removeAll()

        for (role, defaultName) in Self.defaultSounds {
            let customPath = AppSettings.shared.customSound(for: role)
            let url: URL
            if let customPath, FileManager.default.fileExists(atPath: customPath) {
                url = URL(fileURLWithPath: customPath)
                NSLog("[SoundService] Custom sound for '%@': %@", role, customPath)
            } else {
                url = URL(fileURLWithPath: "/System/Library/Sounds/\(defaultName).aiff")
            }

            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay() // Decode + cache — no audible output
                players[role] = player
            } catch {
                NSLog("[SoundService] ⚠️ Failed to load sound '%@': %@", role, error.localizedDescription)
            }
        }
    }

    private func play(_ role: String) {
        guard enabled() else { return }
        guard let player = players[role] else { return }
        player.currentTime = 0
        player.play()
    }

    /// Recording started
    func playStart() { play("start") }

    /// Recording stopped
    func playStop() { play("stop") }

    /// Transcription done — no sound (visual pill handles it)
    func playSuccess() {}

    /// Error — no sound
    func playError() {}

    /// Selection translate started
    func playTranslateStart() { play("translateStart") }

    /// Selection translate done
    func playTranslateDone() { play("translateDone") }
}
