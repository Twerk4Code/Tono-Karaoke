import AVFoundation
import AudioKit

enum DelayMode: String, Codable, CaseIterable {
    case standard
    case slapbackPingPong
}

enum GatePreset: String, Codable, CaseIterable {
    case manual
    case subtleCleanup
    case vocalFocus
    case hardCut

    var title: String {
        switch self {
        case .manual: return "Manual"
        case .subtleCleanup: return "Subtle Cleanup"
        case .vocalFocus: return "Vocal Focus"
        case .hardCut: return "Hard Cut"
        }
    }
}

enum EQPreset: String, Codable, CaseIterable {
    case manual
    case flat
    case vocalPresence
    case warmth

    var title: String {
        switch self {
        case .manual: return "Manual"
        case .flat: return "Flat"
        case .vocalPresence: return "Vocal Presence"
        case .warmth: return "Warmth"
        }
    }
}

enum CompressorPreset: String, Codable, CaseIterable {
    case manual
    case gentleControl
    case vocalLeveler
    case tight

    var title: String {
        switch self {
        case .manual: return "Manual"
        case .gentleControl: return "Gentle Control"
        case .vocalLeveler: return "Vocal Leveler"
        case .tight: return "Tight"
        }
    }
}

enum EffectsDefaults {
    static let gateEnabled = false
    static let eqEnabled = true
    static let compressorEnabled = true
    static let delayEnabled = false
    static let reverbEnabled = false

    static let gatePreset: GatePreset = .subtleCleanup
    static let eqPreset: EQPreset = .flat
    static let compressorPreset: CompressorPreset = .gentleControl

    static let compressorThreshold: Float = -18
    static let compressorRatio: Float = 3
    static let compressorMakeupGain: Float = 0

    static let reverbMix: Float = 0
    static let lowGain: Float = 0
    static let midGain: Float = 0
    static let highGain: Float = 0

    static let gateThreshold: Float = -45
    static let gateRatio: Float = 2.5
    static let gateAttack: Float = 0.005
    static let gateRelease: Float = 0.12

    static func gateSettings(for preset: GatePreset) -> (threshold: Float, ratio: Float, attack: Float, release: Float) {
        switch preset {
        case .manual:
            return (gateThreshold, gateRatio, gateAttack, gateRelease)
        case .subtleCleanup:
            return (-45, 2.5, 0.005, 0.12)
        case .vocalFocus:
            return (-38, 4.0, 0.003, 0.09)
        case .hardCut:
            return (-32, 8.0, 0.002, 0.07)
        }
    }

    static func eqSettings(for preset: EQPreset) -> (low: Float, mid: Float, high: Float) {
        switch preset {
        case .manual:
            return (lowGain, midGain, highGain)
        case .flat:
            return (0, 0, 0)
        case .vocalPresence:
            return (-1.5, 2.5, 2.0)
        case .warmth:
            return (2.0, 1.0, -0.5)
        }
    }

    static func compressorSettings(for preset: CompressorPreset) -> (threshold: Float, ratio: Float, makeup: Float) {
        switch preset {
        case .manual:
            return (compressorThreshold, compressorRatio, compressorMakeupGain)
        case .gentleControl:
            return (-18, 3.0, 0.0)
        case .vocalLeveler:
            return (-16, 4.0, 1.0)
        case .tight:
            return (-12, 6.0, 2.5)
        }
    }

    static func delayMix(for mode: DelayMode) -> Float {
        switch mode {
        case .standard: return 0.22
        case .slapbackPingPong: return 0.30
        }
    }

    static func delayTime(for mode: DelayMode) -> Float {
        switch mode {
        case .standard: return 0.30
        case .slapbackPingPong: return 0.12
        }
    }

    static func delayFeedback(for mode: DelayMode) -> Float {
        switch mode {
        case .standard: return 0.30
        case .slapbackPingPong: return 0.18
        }
    }
}

/// Mic monitoring effects chain.
///
/// Ordered chain:
///   Gate -> EQ -> Compressor -> Delay(Standard | Slapback Ping-Pong) -> Reverb
///
/// The implementation uses a strictly linear audio graph to avoid format
/// negotiation failures on live AVAudioEngine graphs.
@MainActor
final class EffectsProcessor {

    // MARK: - Audio Nodes

    private let gate: Expander
    private let eq: ThreeBandEQ
    private let compressor: Compressor
    private let delay: Delay
    private let reverb: Reverb

    /// Connect this node to downstream mixer(s).
    var output: Node { reverb }

    // MARK: - Effect Enable Flags

    var gateEnabled: Bool = EffectsDefaults.gateEnabled {
        didSet {
            if gateEnabled { gate.start() } else { gate.stop() }
        }
    }

    var eqEnabled: Bool = EffectsDefaults.eqEnabled {
        didSet {
            if eqEnabled { eq.start() } else { eq.stop() }
        }
    }

    var compressorEnabled: Bool = EffectsDefaults.compressorEnabled {
        didSet {
            if compressorEnabled { compressor.start() } else { compressor.stop() }
        }
    }

    var delayEnabled: Bool = EffectsDefaults.delayEnabled {
        didSet { refreshDelayRouting() }
    }

    var reverbEnabled: Bool = EffectsDefaults.reverbEnabled {
        didSet {
            if reverbEnabled { reverb.start() } else { reverb.stop() }
        }
    }

    // MARK: - Delay Mode + Shared Controls

    var delayMode: DelayMode = .standard {
        didSet {
            if delayMode != oldValue {
                debugLog("delay mode switched: \(oldValue.rawValue) -> \(delayMode.rawValue)")
            }
            refreshDelayRouting()
            applyDelayTime()
            applyDelayFeedback()
        }
    }

    /// Wet/dry mix for delay stage.
    var delayMix: Float = EffectsDefaults.delayMix(for: .standard) {
        didSet { refreshDelayRouting() }
    }

    /// Delay time in seconds.
    var delayTime: Float = EffectsDefaults.delayTime(for: .standard) {
        didSet { applyDelayTime() }
    }

    /// Delay feedback normalized 0...0.95.
    var delayFeedback: Float = EffectsDefaults.delayFeedback(for: .standard) {
        didSet { applyDelayFeedback() }
    }

    // MARK: - Init

    init(input: Node) {
        // 1) Gate (downward expansion)
        gate = Expander(
            input,
            expansionRatio: EffectsDefaults.gateRatio,
            expansionThreshold: EffectsDefaults.gateThreshold,
            attackTime: EffectsDefaults.gateAttack,
            releaseTime: EffectsDefaults.gateRelease
        )

        // 2) EQ
        eq = ThreeBandEQ(gate)

        // 3) Compressor (AVAudioUnitDynamicsProcessor wrapper)
        compressor = Compressor(
            eq,
            threshold: EffectsDefaults.compressorThreshold,
            headRoom: EffectsProcessor.ratioToHeadroom(EffectsDefaults.compressorRatio),
            attackTime: 0.002,   // fixed low-latency defaults for v1
            releaseTime: 0.06,
            masterGain: EffectsDefaults.compressorMakeupGain
        )

        // 4) Delay
        delay = Delay(
            compressor,
            time: EffectsDefaults.delayTime(for: .standard),
            feedback: EffectsDefaults.delayFeedback(for: .standard) * 100,
            lowPassCutoff: 15_000,
            dryWetMix: 0
        )

        // 5) Reverb
        reverb = Reverb(delay)
        reverb.dryWetMix = EffectsDefaults.reverbMix
        reverb.stop()

        // Force deterministic startup state (property observers don't fire in init).
        if gateEnabled { gate.start() } else { gate.stop() }
        if eqEnabled { eq.start() } else { eq.stop() }
        if compressorEnabled { compressor.start() } else { compressor.stop() }
        if reverbEnabled { reverb.start() } else { reverb.stop() }
        applyDelayTime()
        applyDelayFeedback()
        refreshDelayRouting()
    }

    // MARK: - Gate (downward expander)

    var gateThreshold: Float {
        get { gate.expansionThreshold }
        set { gate.expansionThreshold = clamp(newValue, -80, 0) }
    }

    var gateRatio: Float {
        get { gate.expansionRatio }
        set { gate.expansionRatio = clamp(newValue, 1, 20) }
    }

    var gateAttack: Float {
        get { gate.attackTime }
        set { gate.attackTime = clamp(newValue, 0.0001, 0.2) }
    }

    var gateRelease: Float {
        get { gate.releaseTime }
        set { gate.releaseTime = clamp(newValue, 0.01, 3.0) }
    }

    // MARK: - Reverb (0 ... 1)

    var reverbMix: Float {
        get { reverb.dryWetMix }
        set { reverb.dryWetMix = clamp(newValue, 0, 1) }
    }

    // MARK: - Compressor

    var compressorThreshold: Float {
        get { compressor.threshold }
        set { compressor.threshold = clamp(newValue, -40, 20) }
    }

    /// User-facing ratio mapped to AVAudioUnitDynamicsProcessor headRoom.
    var compressorRatio: Float {
        get { headroomToRatio(compressor.headRoom) }
        set { compressor.headRoom = EffectsProcessor.ratioToHeadroom(clamp(newValue, 1, 20)) }
    }

    var compressorMakeupGain: Float {
        get { compressor.masterGain }
        set { compressor.masterGain = clamp(newValue, -12, 24) }
    }

    // MARK: - 3-Band EQ (−12 ... +12 dB)

    var lowGain: Float {
        get { eq.lowGain }
        set { eq.lowGain = clamp(newValue, -12, 12) }
    }

    var midGain: Float {
        get { eq.midGain }
        set { eq.midGain = clamp(newValue, -12, 12) }
    }

    var highGain: Float {
        get { eq.highGain }
        set { eq.highGain = clamp(newValue, -12, 12) }
    }

    // MARK: - Delay Helpers

    private func refreshDelayRouting() {
        let mix = clamp(delayMix, 0, 1)
        if delayEnabled {
            delay.start()
            delay.dryWetMix = mix * 100
        } else {
            delay.stop()
            delay.dryWetMix = 0
        }
    }

    private func applyDelayTime() {
        let t = clamp(delayTime, 0.01, 2.0)
        delay.time = t
    }

    private func applyDelayFeedback() {
        let fb = clamp(delayFeedback, 0, 0.95) * 100
        delay.feedback = fb
    }

    private static func ratioToHeadroom(_ ratio: Float) -> Float {
        // Higher ratio => lower headroom => stronger compression.
        clampStatic(40 / max(ratio, 1), 0.1, 40)
    }

    private func headroomToRatio(_ headroom: Float) -> Float {
        clamp(40 / max(headroom, 0.1), 1, 20)
    }

    // MARK: - Private Helpers

    private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        min(max(value, lower), upper)
    }

    private static func clampStatic(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        min(max(value, lower), upper)
    }

    private func debugLog(_ message: String) {
        print("[EffectsProcessor][DEBUG] \(message)")
    }

    func debugDumpNodeFormats(context: String) {
        let nodes: [(String, AVAudioNode)] = [
            ("gate", gate.avAudioNode),
            ("eq", eq.avAudioNode),
            ("compressor", compressor.avAudioNode),
            ("delay", delay.avAudioNode),
            ("reverb", reverb.avAudioNode)
        ]

        for (label, node) in nodes {
            let inputCount = node.numberOfInputs
            if inputCount == 0 {
                print("[EffectsProcessor][DEBUG] \(context) \(label) in=<none>")
            } else {
                for bus in 0..<inputCount {
                    let f = node.inputFormat(forBus: bus)
                    print(
                        "[EffectsProcessor][DEBUG] \(context) \(label) in[\(bus)] " +
                        "sr=\(Int(f.sampleRate)) ch=\(f.channelCount)"
                    )
                }
            }

            let outputCount = node.numberOfOutputs
            if outputCount == 0 {
                print("[EffectsProcessor][DEBUG] \(context) \(label) out=<none>")
            } else {
                for bus in 0..<outputCount {
                    let f = node.outputFormat(forBus: bus)
                    print(
                        "[EffectsProcessor][DEBUG] \(context) \(label) out[\(bus)] " +
                        "sr=\(Int(f.sampleRate)) ch=\(f.channelCount)"
                    )
                }
            }
        }
    }
}
