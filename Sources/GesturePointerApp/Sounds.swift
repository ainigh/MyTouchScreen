#if canImport(AppKit)
import AppKit
import GestureCore

/// Plays Wisp's synthesized feedback sounds. The WAVs are generated once at launch from the
/// recipes in GestureCore's `SoundCue` (no audio files are shipped or committed).
@MainActor
final class Sounds {
    private var sounds: [SoundCue: NSSound] = [:]
    var enabled = true

    init() {
        for cue in SoundCue.allCases {
            if let sound = NSSound(data: cue.wavData()) {
                sounds[cue] = sound
            }
        }
    }

    func play(_ cue: SoundCue) {
        guard enabled, let sound = sounds[cue] else { return }
        // Restart rather than overlap, so rapid clicks stay crisp.
        if sound.isPlaying { sound.stop() }
        sound.play()
    }
}
#endif
