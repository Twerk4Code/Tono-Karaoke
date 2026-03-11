import Foundation
import AudioKit
import SoundpipeAudioKit

/// Real-time pitch detection via AudioKit PitchTap.
/// Tap lifecycle is managed safely — always stop before releasing.
@Observable
@MainActor
final class PitchTracker {

    var currentReading: PitchReading = .silent
    var isTracking = false

    private var pitchTap: PitchTap?
    private let confidenceThreshold: Float

    init(confidenceThreshold: Float = 0.05) {
        self.confidenceThreshold = confidenceThreshold
    }

    /// Start tracking pitch from the given mic input node.
    /// Safe to call multiple times — stops any existing tap first.
    func start(microphone: AudioEngine.InputNode) {
        stopTracking()  // CRITICAL: always stop before creating new tap

        let tap = PitchTap(microphone) { [weak self] pitches, amplitudes in
            Task { @MainActor in
                guard let self else { return }
                let pitch = pitches[0]
                let amplitude = amplitudes[0]
                guard amplitude > self.confidenceThreshold, pitch > 30 else {
                    self.currentReading = .silent
                    return
                }
                let (note, cents) = NoteHelper.noteAndCents(frequency: pitch)
                self.currentReading = PitchReading(
                    frequency: pitch,
                    note: note,
                    cents: cents,
                    timestamp: Date()
                )
            }
        }
        tap.start()
        pitchTap = tap
        isTracking = true
    }

    /// Stop tracking. MUST be called before dismissing PerformanceView or switching songs.
    /// Prevents CoreAudio deadlock.
    func stopTracking() {
        guard let tap = pitchTap else { return }
        tap.stop()
        pitchTap = nil
        isTracking = false
        currentReading = .silent
    }
}
