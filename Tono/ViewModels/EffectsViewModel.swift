import Foundation

/// Bridges EffectsProcessor ↔ SwiftUI and persists values to AppSettings.
///
/// Each property writes to the live audio graph immediately and also saves to
/// AppSettings so values survive app relaunch.
@Observable
@MainActor
final class EffectsViewModel {

    private let appState: AppState
    private var micFx: EffectsProcessor? { appState.audioEngine.micEffects }
    private var settings: AppSettings { appState.settings }
    private var isRestoring = false
    private var isApplyingGatePreset = false
    private var isApplyingEQPreset = false
    private var isApplyingCompressorPreset = false

    // MARK: - Init

    init(appState: AppState) {
        self.appState = appState
        appState.audioEngine.onMicEffectsReady = { [weak self] fx in
            self?.applyCurrentValues(to: fx)
        }
        restoreFromSettings()
        if let micFx {
            applyCurrentValues(to: micFx)
        }
    }

    // MARK: - Enable Flags

    var gateEnabled: Bool = EffectsDefaults.gateEnabled {
        didSet {
            micFx?.gateEnabled = gateEnabled
            persist { settings.gateEnabled = gateEnabled }
        }
    }

    var eqEnabled: Bool = EffectsDefaults.eqEnabled {
        didSet {
            micFx?.eqEnabled = eqEnabled
            persist { settings.eqEnabled = eqEnabled }
        }
    }

    var compressorEnabled: Bool = EffectsDefaults.compressorEnabled {
        didSet {
            micFx?.compressorEnabled = compressorEnabled
            persist { settings.compressorEnabled = compressorEnabled }
        }
    }

    var delayEnabled: Bool = EffectsDefaults.delayEnabled {
        didSet {
            micFx?.delayEnabled = delayEnabled
            persist { settings.delayEnabled = delayEnabled }
        }
    }

    var reverbEnabled: Bool = EffectsDefaults.reverbEnabled {
        didSet {
            micFx?.reverbEnabled = reverbEnabled
            persist { settings.reverbEnabled = reverbEnabled }
        }
    }

    // MARK: - Gate

    var gatePreset: GatePreset = EffectsDefaults.gatePreset {
        didSet {
            persist { settings.gatePreset = gatePreset.rawValue }
            guard !isRestoring, !isApplyingGatePreset else { return }
            guard gatePreset != .manual else { return }
            applyGatePreset(gatePreset)
        }
    }

    var gateThreshold: Double = Double(EffectsDefaults.gateThreshold) {
        didSet {
            let v = clamp(Float(gateThreshold), -80, 0)
            micFx?.gateThreshold = v
            persist { settings.gateThreshold = v }
            if !isRestoring, !isApplyingGatePreset, gatePreset != .manual {
                gatePreset = .manual
            }
        }
    }

    var gateRatio: Double = Double(EffectsDefaults.gateRatio) {
        didSet {
            let v = clamp(Float(gateRatio), 1, 20)
            micFx?.gateRatio = v
            persist { settings.gateRatio = v }
            if !isRestoring, !isApplyingGatePreset, gatePreset != .manual {
                gatePreset = .manual
            }
        }
    }

    var gateAttack: Double = Double(EffectsDefaults.gateAttack) {
        didSet {
            let v = clamp(Float(gateAttack), 0.0001, 0.2)
            micFx?.gateAttack = v
            persist { settings.gateAttack = v }
            if !isRestoring, !isApplyingGatePreset, gatePreset != .manual {
                gatePreset = .manual
            }
        }
    }

    var gateRelease: Double = Double(EffectsDefaults.gateRelease) {
        didSet {
            let v = clamp(Float(gateRelease), 0.01, 3.0)
            micFx?.gateRelease = v
            persist { settings.gateRelease = v }
            if !isRestoring, !isApplyingGatePreset, gatePreset != .manual {
                gatePreset = .manual
            }
        }
    }

    // MARK: - EQ (−12 … +12 dB)

    var eqPreset: EQPreset = EffectsDefaults.eqPreset {
        didSet {
            persist { settings.eqPreset = eqPreset.rawValue }
            guard !isRestoring, !isApplyingEQPreset else { return }
            guard eqPreset != .manual else { return }
            applyEQPreset(eqPreset)
        }
    }

    // MARK: - EQ (−12 … +12 dB)

    var lowGain: Double = Double(EffectsDefaults.lowGain) {
        didSet {
            let v = clamp(Float(lowGain), -12, 12)
            micFx?.lowGain = v
            persist { settings.lowGain = v }
            if !isRestoring, !isApplyingEQPreset, eqPreset != .manual {
                eqPreset = .manual
            }
        }
    }

    var midGain: Double = Double(EffectsDefaults.midGain) {
        didSet {
            let v = clamp(Float(midGain), -12, 12)
            micFx?.midGain = v
            persist { settings.midGain = v }
            if !isRestoring, !isApplyingEQPreset, eqPreset != .manual {
                eqPreset = .manual
            }
        }
    }

    var highGain: Double = Double(EffectsDefaults.highGain) {
        didSet {
            let v = clamp(Float(highGain), -12, 12)
            micFx?.highGain = v
            persist { settings.highGain = v }
            if !isRestoring, !isApplyingEQPreset, eqPreset != .manual {
                eqPreset = .manual
            }
        }
    }

    // MARK: - Compressor

    var compressorPreset: CompressorPreset = EffectsDefaults.compressorPreset {
        didSet {
            persist { settings.compressorPreset = compressorPreset.rawValue }
            guard !isRestoring, !isApplyingCompressorPreset else { return }
            guard compressorPreset != .manual else { return }
            applyCompressorPreset(compressorPreset)
        }
    }

    var compressorThreshold: Double = Double(EffectsDefaults.compressorThreshold) {
        didSet {
            let v = clamp(Float(compressorThreshold), -40, 20)
            micFx?.compressorThreshold = v
            persist { settings.compressorThreshold = v }
            if !isRestoring, !isApplyingCompressorPreset, compressorPreset != .manual {
                compressorPreset = .manual
            }
        }
    }

    var compressorRatio: Double = Double(EffectsDefaults.compressorRatio) {
        didSet {
            let v = clamp(Float(compressorRatio), 1, 20)
            micFx?.compressorRatio = v
            persist { settings.compressorRatio = v }
            if !isRestoring, !isApplyingCompressorPreset, compressorPreset != .manual {
                compressorPreset = .manual
            }
        }
    }

    var compressorMakeupGain: Double = Double(EffectsDefaults.compressorMakeupGain) {
        didSet {
            let v = clamp(Float(compressorMakeupGain), -12, 24)
            micFx?.compressorMakeupGain = v
            persist { settings.compressorMakeupGain = v }
            if !isRestoring, !isApplyingCompressorPreset, compressorPreset != .manual {
                compressorPreset = .manual
            }
        }
    }

    // MARK: - Delay

    var delayMode: DelayMode = .standard {
        didSet {
            micFx?.delayMode = delayMode
            persist { settings.delayMode = delayMode.rawValue }
            guard !isRestoring else { return }
            applyDelayDefaults(for: delayMode)
        }
    }

    var delayMix: Double = Double(EffectsDefaults.delayMix(for: .standard)) {
        didSet {
            let v = clamp(Float(delayMix), 0, 1)
            micFx?.delayMix = v
            persist { settings.delayMix = v }
        }
    }

    var delayTime: Double = Double(EffectsDefaults.delayTime(for: .standard)) {
        didSet {
            let v = clamp(Float(delayTime), 0.01, 2.0)
            micFx?.delayTime = v
            persist { settings.delayTime = v }
        }
    }

    var delayFeedback: Double = Double(EffectsDefaults.delayFeedback(for: .standard)) {
        didSet {
            let v = clamp(Float(delayFeedback), 0, 0.95)
            micFx?.delayFeedback = v
            persist { settings.delayFeedback = v }
        }
    }

    // MARK: - Reverb

    var reverbMix: Double = Double(EffectsDefaults.reverbMix) {
        didSet {
            let v = clamp(Float(reverbMix), 0, 1)
            micFx?.reverbMix = v
            persist { settings.reverbMix = v }
        }
    }

    // MARK: - Convenience

    var isAnyEffectActive: Bool {
        gateEnabled || eqEnabled || compressorEnabled || delayEnabled || reverbEnabled
    }

    func resetAll() {
        gateEnabled = EffectsDefaults.gateEnabled
        eqEnabled = EffectsDefaults.eqEnabled
        compressorEnabled = EffectsDefaults.compressorEnabled
        delayEnabled = EffectsDefaults.delayEnabled
        reverbEnabled = EffectsDefaults.reverbEnabled

        gatePreset = EffectsDefaults.gatePreset
        if gatePreset == .manual {
            gateThreshold = Double(EffectsDefaults.gateThreshold)
            gateRatio = Double(EffectsDefaults.gateRatio)
            gateAttack = Double(EffectsDefaults.gateAttack)
            gateRelease = Double(EffectsDefaults.gateRelease)
        }

        eqPreset = EffectsDefaults.eqPreset
        if eqPreset == .manual {
            lowGain = Double(EffectsDefaults.lowGain)
            midGain = Double(EffectsDefaults.midGain)
            highGain = Double(EffectsDefaults.highGain)
        }

        compressorPreset = EffectsDefaults.compressorPreset
        if compressorPreset == .manual {
            compressorThreshold = Double(EffectsDefaults.compressorThreshold)
            compressorRatio = Double(EffectsDefaults.compressorRatio)
            compressorMakeupGain = Double(EffectsDefaults.compressorMakeupGain)
        }

        delayMode = .standard
        delayMix = Double(EffectsDefaults.delayMix(for: .standard))
        delayTime = Double(EffectsDefaults.delayTime(for: .standard))
        delayFeedback = Double(EffectsDefaults.delayFeedback(for: .standard))

        reverbMix = Double(EffectsDefaults.reverbMix)
    }

    // MARK: - Private

    private func restoreFromSettings() {
        isRestoring = true

        gateEnabled = settings.gateEnabled
        eqEnabled = settings.eqEnabled
        compressorEnabled = settings.compressorEnabled
        delayEnabled = settings.delayEnabled
        reverbEnabled = settings.reverbEnabled

        gatePreset = GatePreset(rawValue: settings.gatePreset) ?? .manual
        eqPreset = EQPreset(rawValue: settings.eqPreset) ?? .manual
        compressorPreset = CompressorPreset(rawValue: settings.compressorPreset) ?? .manual

        gateThreshold = Double(settings.gateThreshold)
        gateRatio = Double(settings.gateRatio)
        gateAttack = Double(settings.gateAttack)
        gateRelease = Double(settings.gateRelease)

        lowGain = Double(settings.lowGain)
        midGain = Double(settings.midGain)
        highGain = Double(settings.highGain)

        compressorThreshold = Double(settings.compressorThreshold)
        compressorRatio = Double(settings.compressorRatio)
        compressorMakeupGain = Double(settings.compressorMakeupGain)

        if let decodedDelayMode = DelayMode(rawValue: settings.delayMode) {
            delayMode = decodedDelayMode
        } else {
            delayMode = .standard
        }
        delayMix = Double(settings.delayMix)
        delayTime = Double(settings.delayTime)
        delayFeedback = Double(settings.delayFeedback)

        reverbMix = Double(settings.reverbMix)
        isRestoring = false
    }

    private func applyCurrentValues(to fx: EffectsProcessor) {
        fx.gateEnabled = gateEnabled
        fx.eqEnabled = eqEnabled
        fx.compressorEnabled = compressorEnabled
        fx.delayEnabled = delayEnabled
        fx.reverbEnabled = reverbEnabled

        fx.gateThreshold = Float(gateThreshold)
        fx.gateRatio = Float(gateRatio)
        fx.gateAttack = Float(gateAttack)
        fx.gateRelease = Float(gateRelease)

        fx.lowGain = Float(lowGain)
        fx.midGain = Float(midGain)
        fx.highGain = Float(highGain)

        fx.compressorThreshold = Float(compressorThreshold)
        fx.compressorRatio = Float(compressorRatio)
        fx.compressorMakeupGain = Float(compressorMakeupGain)

        fx.delayMode = delayMode
        fx.delayMix = Float(delayMix)
        fx.delayTime = Float(delayTime)
        fx.delayFeedback = Float(delayFeedback)

        fx.reverbMix = Float(reverbMix)
    }

    private func applyDelayDefaults(for mode: DelayMode) {
        delayMix = Double(EffectsDefaults.delayMix(for: mode))
        delayTime = Double(EffectsDefaults.delayTime(for: mode))
        delayFeedback = Double(EffectsDefaults.delayFeedback(for: mode))
    }

    private func applyGatePreset(_ preset: GatePreset) {
        let s = EffectsDefaults.gateSettings(for: preset)
        isApplyingGatePreset = true
        gateThreshold = Double(s.threshold)
        gateRatio = Double(s.ratio)
        gateAttack = Double(s.attack)
        gateRelease = Double(s.release)
        isApplyingGatePreset = false
    }

    private func applyEQPreset(_ preset: EQPreset) {
        let s = EffectsDefaults.eqSettings(for: preset)
        isApplyingEQPreset = true
        lowGain = Double(s.low)
        midGain = Double(s.mid)
        highGain = Double(s.high)
        isApplyingEQPreset = false
    }

    private func applyCompressorPreset(_ preset: CompressorPreset) {
        let s = EffectsDefaults.compressorSettings(for: preset)
        isApplyingCompressorPreset = true
        compressorThreshold = Double(s.threshold)
        compressorRatio = Double(s.ratio)
        compressorMakeupGain = Double(s.makeup)
        isApplyingCompressorPreset = false
    }

    private func persist(_ save: () -> Void) {
        guard !isRestoring else { return }
        save()
    }

    private func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        min(max(value, lower), upper)
    }
}
