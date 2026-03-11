@preconcurrency import AVFoundation
@preconcurrency import AudioKit

/// 3-band parametric EQ using Apple's built-in AVAudioUnitEQ.
///
/// Unlike SoundpipeAudioKit's EqualizerFilter, AVAudioUnitEQ uses direct properties
/// for band parameters — NOT AUParameter.setValue() — so it's safe to configure
/// before the AudioKit engine is running. This avoids kAudioUnitErr_InvalidParameter.
@MainActor
final class ThreeBandEQ: @preconcurrency Node {

    let connections: [Node]
    let avAudioNode: AVAudioNode

    private let eqUnit: AVAudioUnitEQ

    // MARK: - Init

    init(_ input: Node) {
        eqUnit = AVAudioUnitEQ(numberOfBands: 3)
        avAudioNode = eqUnit
        connections = [input]

        // Low band — 200 Hz
        let low = eqUnit.bands[0]
        low.filterType = .parametric
        low.frequency = 200
        low.bandwidth = 1.0   // octaves
        low.gain = 0
        low.bypass = false

        // Mid band — 1 kHz
        let mid = eqUnit.bands[1]
        mid.filterType = .parametric
        mid.frequency = 1_000
        mid.bandwidth = 1.0
        mid.gain = 0
        mid.bypass = false

        // High band — 8 kHz
        let high = eqUnit.bands[2]
        high.filterType = .parametric
        high.frequency = 8_000
        high.bandwidth = 1.0
        high.gain = 0
        high.bypass = false
    }

    // MARK: - Gain (−12 … +12 dB)

    var lowGain: Float {
        get { eqUnit.bands[0].gain }
        set { eqUnit.bands[0].gain = newValue }
    }

    var midGain: Float {
        get { eqUnit.bands[1].gain }
        set { eqUnit.bands[1].gain = newValue }
    }

    var highGain: Float {
        get { eqUnit.bands[2].gain }
        set { eqUnit.bands[2].gain = newValue }
    }
}
