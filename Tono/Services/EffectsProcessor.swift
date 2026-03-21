import AVFoundation
import AudioKit
import SoundpipeAudioKit
import Foundation

enum TunerKey: String, Codable, CaseIterable {
    case cKey = "C"
    case cSharp = "C#"
    case dKey = "D"
    case dSharp = "D#"
    case eKey = "E"
    case fKey = "F"
    case fSharp = "F#"
    case gKey = "G"
    case gSharp = "G#"
    case aKey = "A"
    case aSharp = "A#"
    case bKey = "B"

    var title: String { rawValue }

    var semitoneOffset: Int {
        switch self {
        case .cKey: return 0
        case .cSharp: return 1
        case .dKey: return 2
        case .dSharp: return 3
        case .eKey: return 4
        case .fKey: return 5
        case .fSharp: return 6
        case .gKey: return 7
        case .gSharp: return 8
        case .aKey: return 9
        case .aSharp: return 10
        case .bKey: return 11
        }
    }
}

enum TunerScale: String, Codable, CaseIterable {
    case major
    case minor
    case chromatic

    var title: String {
        switch self {
        case .major: return "Major"
        case .minor: return "Minor"
        case .chromatic: return "Chromatic"
        }
    }

    private var intervals: Set<Int> {
        switch self {
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .chromatic: return Set(0...11)
        }
    }

    func frequencies(for key: TunerKey, minFrequency: Float, maxFrequency: Float) -> [Float] {
        var frequencies: [Float] = []
        for midiNote in 0...127 {
            let scaleDegree = ((midiNote % 12) - key.semitoneOffset + 12) % 12
            guard intervals.contains(scaleDegree) else { continue }
            let frequency = Self.frequency(forMIDINote: midiNote)
            guard frequency >= minFrequency, frequency <= maxFrequency else { continue }
            frequencies.append(frequency)
        }
        return frequencies
    }

    private static func frequency(forMIDINote midiNote: Int) -> Float {
        let exponent = (Double(midiNote) - 69.0) / 12.0
        return Float(440.0 * pow(2.0, exponent))
    }
}

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
    static let tunerEnabled = false
    static let delayEnabled = false
    static let reverbEnabled = false

    static let gatePreset: GatePreset = .subtleCleanup
    static let eqPreset: EQPreset = .flat
    static let compressorPreset: CompressorPreset = .gentleControl

    static let compressorThreshold: Float = -18
    static let compressorRatio: Float = 3
    static let compressorMakeupGain: Float = 0
    static let tunerKey: TunerKey = .cKey
    static let tunerScale: TunerScale = .chromatic
    static let tunerAmount: Float = 0.75
    static let tunerSpeed: Float = 0.55

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
///   Gate -> EQ -> Compressor -> Tuner -> Delay(Standard | Slapback Ping-Pong) -> Reverb
///
/// The implementation uses a strictly linear audio graph to avoid format
/// negotiation failures on live AVAudioEngine graphs.
@MainActor
final class EffectsProcessor {

    // MARK: - Audio Nodes

    private let gate: Expander
    private let eq: ThreeBandEQ
    private let compressor: Compressor
    private let pitchCorrect: PitchCorrect
    private let delay: Delay
    private let reverb: Reverb
    private static var diagnosticsEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["TONO_AUDIO_DEBUG_LOGS"] == "1"
#else
        false
#endif
    }

    /// Connect this node to downstream mixer(s).
    var output: Node { reverb }
    /// Preferred source for pitch tracking taps (pre-tuner).
    var pitchTrackingOutput: Node { compressor }

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

    var tunerEnabled: Bool = EffectsDefaults.tunerEnabled {
        didSet { refreshTunerState() }
    }

    var tunerKey: TunerKey = EffectsDefaults.tunerKey {
        didSet { applyTunerScaleFrequencies() }
    }

    var tunerScale: TunerScale = EffectsDefaults.tunerScale {
        didSet { applyTunerScaleFrequencies() }
    }

    var tunerAmount: Float = EffectsDefaults.tunerAmount {
        didSet { applyTunerAmount() }
    }

    var tunerSpeed: Float = EffectsDefaults.tunerSpeed {
        didSet { applyTunerSpeed() }
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

        // 4) Tuner
        pitchCorrect = PitchCorrect(
            compressor,
            speed: EffectsDefaults.tunerSpeed,
            amount: EffectsDefaults.tunerAmount
        )

        // 5) Delay
        delay = Delay(
            pitchCorrect,
            time: EffectsDefaults.delayTime(for: .standard),
            feedback: EffectsDefaults.delayFeedback(for: .standard) * 100,
            lowPassCutoff: 15_000,
            dryWetMix: 0
        )

        // 6) Reverb
        reverb = Reverb(delay)
        reverb.dryWetMix = EffectsDefaults.reverbMix
        reverb.stop()

        // Force deterministic startup state (property observers don't fire in init).
        if gateEnabled { gate.start() } else { gate.stop() }
        if eqEnabled { eq.start() } else { eq.stop() }
        if compressorEnabled { compressor.start() } else { compressor.stop() }
        applyTunerScaleFrequencies()
        applyTunerAmount()
        applyTunerSpeed()
        refreshTunerState()
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

    // MARK: - Tuner

    private let minTunerFrequency: Float = 20
    private let maxTunerFrequency: Float = 3_000
    /// SoundpipeAudioKit's PitchCorrect DSP frees its cached scale table when
    /// render resources are deallocated, so the host must re-send it before
    /// the next engine start.
    private var tunerDSPStateNeedsRebuild = true

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

    private func refreshTunerState() {
        if tunerEnabled {
            pitchCorrect.start()
        } else {
            pitchCorrect.stop()
        }
    }

    private func applyTunerScaleFrequencies() {
        let frequencies = tunerScale.frequencies(
            for: tunerKey,
            minFrequency: minTunerFrequency,
            maxFrequency: maxTunerFrequency
        )
        guard !frequencies.isEmpty else { return }
        pitchCorrect.setScaleFrequencies(frequencies)
    }

    private func applyTunerAmount() {
        pitchCorrect.amount = clamp(tunerAmount, 0, 1)
    }

    private func applyTunerSpeed() {
        pitchCorrect.speed = clamp(tunerSpeed, 0, 1)
    }

    /// Mark transient tuner DSP state that must be restored before the next start.
    func markRenderResourcesInvalidated() {
        tunerDSPStateNeedsRebuild = true
    }

    /// Rehydrate transient tuner DSP state after AVAudioEngine tears down render resources.
    func prepareForEngineStart() {
        guard tunerDSPStateNeedsRebuild else { return }
        tunerDSPStateNeedsRebuild = false
        debugLog("rehydrating tuner DSP state before engine start")
        applyTunerScaleFrequencies()
        applyTunerAmount()
        applyTunerSpeed()
        refreshTunerState()
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
        guard Self.diagnosticsEnabled else { return }
        print("[EffectsProcessor][DEBUG] \(message)")
    }

    func debugDumpNodeFormats(context: String) {
        guard Self.diagnosticsEnabled else { return }
        let nodes: [(String, AVAudioNode)] = [
            ("gate", gate.avAudioNode),
            ("eq", eq.avAudioNode),
            ("compressor", compressor.avAudioNode),
            ("tuner", pitchCorrect.avAudioNode),
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
