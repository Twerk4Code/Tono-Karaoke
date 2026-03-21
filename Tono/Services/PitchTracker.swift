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

    /// Optional callback invoked on each valid pitch reading (main thread).
    var onPitchReading: (@MainActor (Float) -> Void)?

    private var pitchTap: PitchTap?
    /// The node the current PitchTap is installed on, used to skip redundant restarts.
    private weak var trackedNode: Node?
    private var confidenceThreshold: Float

    init(confidenceThreshold: Float = 0.001) {
        self.confidenceThreshold = max(0, confidenceThreshold)
    }

    func setConfidenceThreshold(_ value: Float) {
        confidenceThreshold = max(0, value)
    }

    /// Start tracking pitch from the given source node.
    /// Safe to call multiple times — stops any existing tap first.
    /// If already tracking on the same node, this is a no-op to avoid
    /// destroying a working PitchTap with a redundant replacement.
    @discardableResult
    func start(inputNode: Node) -> Bool {
        // Skip redundant restart if already tracking on the same node.
        if isTracking, let existingNode = trackedNode,
           existingNode === inputNode {
            return true
        }
        stopTracking()  // CRITICAL: always stop before creating new tap

        let audioNode = inputNode.avAudioNode
        let outputFormat = audioNode.outputFormat(forBus: 0)
        guard audioNode.engine != nil,
              outputFormat.sampleRate > 0,
              outputFormat.channelCount > 0 else {
            return false
        }

        let tap = PitchTap(inputNode) { [weak self] pitches, amplitudes in
            Task { @MainActor in
                guard let self else { return }
                let source = self.strongestPitchSample(
                    pitches: pitches,
                    amplitudes: amplitudes
                )
                guard let source,
                      source.amplitude > self.confidenceThreshold,
                      source.pitch > 30 else {
                    self.currentReading = .silent
                    return
                }
                let (note, cents) = NoteHelper.noteAndCents(frequency: source.pitch)
                self.currentReading = PitchReading(
                    frequency: source.pitch,
                    note: note,
                    cents: cents,
                    timestamp: Date()
                )
                self.onPitchReading?(source.pitch)
            }
        }
        tap.start()
        pitchTap = tap
        trackedNode = inputNode
        isTracking = true
        return true
    }

    private func strongestPitchSample(
        pitches: [Float],
        amplitudes: [Float]
    ) -> (pitch: Float, amplitude: Float)? {
        let count = min(pitches.count, amplitudes.count)
        guard count > 0 else { return nil }

        var bestPitch = pitches[0]
        var bestAmplitude = amplitudes[0]
        guard count > 1 else { return (bestPitch, bestAmplitude) }

        for index in 1..<count {
            let amplitude = amplitudes[index]
            if amplitude > bestAmplitude {
                bestAmplitude = amplitude
                bestPitch = pitches[index]
            }
        }
        return (bestPitch, bestAmplitude)
    }

    /// Stop tracking. MUST be called before dismissing PerformanceView or switching songs.
    /// Prevents CoreAudio deadlock.
    func stopTracking() {
        if let tap = pitchTap {
            tap.stop()
        }
        pitchTap = nil
        trackedNode = nil
        isTracking = false
        currentReading = .silent
    }
}
