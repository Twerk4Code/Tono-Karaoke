import Foundation

@Observable
final class AppSettings: Codable {
    var selectedInputDeviceID: String? {
        didSet { autosave() }
    }
    var selectedOutputDeviceID: String? {
        didSet { autosave() }
    }
    var bufferFrameSize: UInt32? {
        didSet { autosave() }
    }
    var pitchConfidenceThreshold: Float = 0.05 {
        didSet { autosave() }
    }
    var defaultVocalVolume: Double = 1.0 {
        didSet { autosave() }
    }
    var defaultInstrumentalVolume: Double = 1.0 {
        didSet { autosave() }
    }
    var playbackRate: Double = 1.0 {
        didSet { autosave() }
    }
    var pitchShiftSemitones: Int = 0 {
        didSet { autosave() }
    }
    var visualizer: VisualizerSettings = .init() {
        didSet { autosave() }
    }

    // MARK: - Effects (persisted globally)
    var gateEnabled: Bool = EffectsDefaults.gateEnabled {
        didSet { autosave() }
    }
    var gateThreshold: Float = EffectsDefaults.gateThreshold {
        didSet { autosave() }
    }
    var gateRatio: Float = EffectsDefaults.gateRatio {
        didSet { autosave() }
    }
    var gateAttack: Float = EffectsDefaults.gateAttack {
        didSet { autosave() }
    }
    var gateRelease: Float = EffectsDefaults.gateRelease {
        didSet { autosave() }
    }
    var gatePreset: String = EffectsDefaults.gatePreset.rawValue {
        didSet { autosave() }
    }
    var eqPreset: String = EffectsDefaults.eqPreset.rawValue {
        didSet { autosave() }
    }
    var compressorPreset: String = EffectsDefaults.compressorPreset.rawValue {
        didSet { autosave() }
    }
    var tunerEnabled: Bool = EffectsDefaults.tunerEnabled {
        didSet { autosave() }
    }
    var tunerKey: String = EffectsDefaults.tunerKey.rawValue {
        didSet { autosave() }
    }
    var tunerScale: String = EffectsDefaults.tunerScale.rawValue {
        didSet { autosave() }
    }
    var tunerAmount: Float = EffectsDefaults.tunerAmount {
        didSet { autosave() }
    }
    var tunerSpeed: Float = EffectsDefaults.tunerSpeed {
        didSet { autosave() }
    }
    var reverbMix: Float = EffectsDefaults.reverbMix {
        didSet { autosave() }
    }
    var delayMix: Float = EffectsDefaults.delayMix(for: .standard) {
        didSet { autosave() }
    }
    var delayTime: Float = EffectsDefaults.delayTime(for: .standard) {
        didSet { autosave() }
    }
    var delayFeedback: Float = EffectsDefaults.delayFeedback(for: .standard) {
        didSet { autosave() }
    }
    var delayMode: String = DelayMode.standard.rawValue {
        didSet { autosave() }
    }
    var eqEnabled: Bool = EffectsDefaults.eqEnabled {
        didSet { autosave() }
    }
    var compressorEnabled: Bool = EffectsDefaults.compressorEnabled {
        didSet { autosave() }
    }
    var delayEnabled: Bool = EffectsDefaults.delayEnabled {
        didSet { autosave() }
    }
    var reverbEnabled: Bool = EffectsDefaults.reverbEnabled {
        didSet { autosave() }
    }
    var compressorThreshold: Float = EffectsDefaults.compressorThreshold {
        didSet { autosave() }
    }
    var compressorRatio: Float = EffectsDefaults.compressorRatio {
        didSet { autosave() }
    }
    var compressorMakeupGain: Float = EffectsDefaults.compressorMakeupGain {
        didSet { autosave() }
    }
    var lowGain: Float = EffectsDefaults.lowGain {
        didSet { autosave() }
    }
    var midGain: Float = EffectsDefaults.midGain {
        didSet { autosave() }
    }
    var highGain: Float = EffectsDefaults.highGain {
        didSet { autosave() }
    }

    private static let persistenceKey = "com.tono.settings"
    private static let autosaveDebounceSeconds: TimeInterval = 0.35
    private var pendingAutosaveWorkItem: DispatchWorkItem?

    enum CodingKeys: String, CodingKey {
        case selectedInputDeviceID
        case selectedOutputDeviceID
        case bufferFrameSize
        case pitchConfidenceThreshold
        case defaultVocalVolume
        case defaultInstrumentalVolume
        case playbackRate
        case pitchShiftSemitones
        case visualizer
        case visualizerEnabled
        case visualizerIntensity
        case gateEnabled, gateThreshold, gateRatio, gateAttack, gateRelease, gatePreset
        case eqPreset, compressorPreset
        case tunerEnabled, tunerKey, tunerScale, tunerAmount, tunerSpeed
        case reverbMix, delayMix, delayTime, delayFeedback, delayMode
        case eqEnabled, compressorEnabled, delayEnabled, reverbEnabled
        case compressorThreshold, compressorRatio, compressorMakeupGain
        case lowGain, midGain, highGain
        // Legacy keys for decode migration.
        case echoMix, echoTime, echoFeedback
    }

    init() {}

    deinit {
        pendingAutosaveWorkItem?.cancel()
    }

    static func load() -> AppSettings {
        let url = settingsURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        FileWriteDeduper.shared.seedLastWrittenData(data, forKey: persistenceKey)
        return decoded
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedInputDeviceID     = try c.decodeIfPresent(String.self,  forKey: .selectedInputDeviceID)
        selectedOutputDeviceID    = try c.decodeIfPresent(String.self,  forKey: .selectedOutputDeviceID)
        bufferFrameSize           = try c.decodeIfPresent(UInt32.self,  forKey: .bufferFrameSize)
        pitchConfidenceThreshold  = try c.decodeIfPresent(Float.self,   forKey: .pitchConfidenceThreshold) ?? 0.05
        defaultVocalVolume        = try c.decodeIfPresent(Double.self, forKey: .defaultVocalVolume)        ?? 1.0
        defaultInstrumentalVolume = try c.decodeIfPresent(Double.self, forKey: .defaultInstrumentalVolume) ?? 1.0
        playbackRate              = try c.decodeIfPresent(Double.self, forKey: .playbackRate)              ?? 1.0
        pitchShiftSemitones       = try c.decodeIfPresent(Int.self,    forKey: .pitchShiftSemitones)       ?? 0
        if let decodedVisualizer = try c.decodeIfPresent(VisualizerSettings.self, forKey: .visualizer) {
            visualizer = Self.sanitizedVisualizerSettings(decodedVisualizer)
        } else {
            let legacyIntensity = try c.decodeIfPresent(Double.self, forKey: .visualizerIntensity) ?? 0.35
            visualizer = VisualizerSettings(
                isEnabled: try c.decodeIfPresent(Bool.self, forKey: .visualizerEnabled) ?? false,
                intensity: Self.sanitizedVisualizerIntensity(legacyIntensity),
                placement: .lyricsPane,
                style: .appleMovie,
                readabilityScrim: 0.42
            )
        }

        gateEnabled = try c.decodeIfPresent(Bool.self, forKey: .gateEnabled) ?? EffectsDefaults.gateEnabled
        gateThreshold = try c.decodeIfPresent(Float.self, forKey: .gateThreshold) ?? EffectsDefaults.gateThreshold
        gateRatio = try c.decodeIfPresent(Float.self, forKey: .gateRatio) ?? EffectsDefaults.gateRatio
        gateAttack = try c.decodeIfPresent(Float.self, forKey: .gateAttack) ?? EffectsDefaults.gateAttack
        gateRelease = try c.decodeIfPresent(Float.self, forKey: .gateRelease) ?? EffectsDefaults.gateRelease

        let decodedGatePreset = try c.decodeIfPresent(String.self, forKey: .gatePreset) ?? GatePreset.manual.rawValue
        gatePreset = GatePreset(rawValue: decodedGatePreset)?.rawValue ?? GatePreset.manual.rawValue
        let decodedEQPreset = try c.decodeIfPresent(String.self, forKey: .eqPreset) ?? EQPreset.manual.rawValue
        eqPreset = EQPreset(rawValue: decodedEQPreset)?.rawValue ?? EQPreset.manual.rawValue
        let decodedCompressorPreset =
            try c.decodeIfPresent(String.self, forKey: .compressorPreset) ?? CompressorPreset.manual.rawValue
        compressorPreset = CompressorPreset(rawValue: decodedCompressorPreset)?.rawValue ?? CompressorPreset.manual.rawValue
        tunerEnabled = try c.decodeIfPresent(Bool.self, forKey: .tunerEnabled) ?? EffectsDefaults.tunerEnabled
        let decodedTunerKey = try c.decodeIfPresent(String.self, forKey: .tunerKey) ?? EffectsDefaults.tunerKey.rawValue
        tunerKey = TunerKey(rawValue: decodedTunerKey)?.rawValue ?? EffectsDefaults.tunerKey.rawValue
        let decodedTunerScale = try c.decodeIfPresent(String.self, forKey: .tunerScale) ?? EffectsDefaults.tunerScale.rawValue
        tunerScale = TunerScale(rawValue: decodedTunerScale)?.rawValue ?? EffectsDefaults.tunerScale.rawValue
        tunerAmount = try c.decodeIfPresent(Float.self, forKey: .tunerAmount) ?? EffectsDefaults.tunerAmount
        tunerSpeed = try c.decodeIfPresent(Float.self, forKey: .tunerSpeed) ?? EffectsDefaults.tunerSpeed

        let decodedDelayModeRaw = try c.decodeIfPresent(String.self, forKey: .delayMode) ?? DelayMode.standard.rawValue
        let decodedDelayMode = DelayMode(rawValue: decodedDelayModeRaw) ?? .standard
        delayMode = decodedDelayMode.rawValue

        reverbMix = try c.decodeIfPresent(Float.self, forKey: .reverbMix) ?? EffectsDefaults.reverbMix
        delayMix =
            try c.decodeIfPresent(Float.self, forKey: .delayMix) ??
            (try c.decodeIfPresent(Float.self, forKey: .echoMix)) ??
            EffectsDefaults.delayMix(for: decodedDelayMode)
        delayTime =
            try c.decodeIfPresent(Float.self, forKey: .delayTime) ??
            (try c.decodeIfPresent(Float.self, forKey: .echoTime)) ??
            EffectsDefaults.delayTime(for: decodedDelayMode)
        delayFeedback =
            try c.decodeIfPresent(Float.self, forKey: .delayFeedback) ??
            (try c.decodeIfPresent(Float.self, forKey: .echoFeedback)) ??
            EffectsDefaults.delayFeedback(for: decodedDelayMode)

        eqEnabled = try c.decodeIfPresent(Bool.self, forKey: .eqEnabled) ?? EffectsDefaults.eqEnabled
        compressorEnabled = try c.decodeIfPresent(Bool.self, forKey: .compressorEnabled) ?? EffectsDefaults.compressorEnabled
        delayEnabled = try c.decodeIfPresent(Bool.self, forKey: .delayEnabled) ?? EffectsDefaults.delayEnabled
        reverbEnabled = try c.decodeIfPresent(Bool.self, forKey: .reverbEnabled) ?? EffectsDefaults.reverbEnabled

        compressorThreshold = try c.decodeIfPresent(Float.self, forKey: .compressorThreshold) ?? EffectsDefaults.compressorThreshold
        compressorRatio = try c.decodeIfPresent(Float.self, forKey: .compressorRatio) ?? EffectsDefaults.compressorRatio
        compressorMakeupGain = try c.decodeIfPresent(Float.self, forKey: .compressorMakeupGain) ?? EffectsDefaults.compressorMakeupGain

        lowGain = try c.decodeIfPresent(Float.self, forKey: .lowGain) ?? EffectsDefaults.lowGain
        midGain = try c.decodeIfPresent(Float.self, forKey: .midGain) ?? EffectsDefaults.midGain
        highGain = try c.decodeIfPresent(Float.self, forKey: .highGain) ?? EffectsDefaults.highGain

    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(selectedInputDeviceID,  forKey: .selectedInputDeviceID)
        try c.encodeIfPresent(selectedOutputDeviceID, forKey: .selectedOutputDeviceID)
        try c.encodeIfPresent(bufferFrameSize,         forKey: .bufferFrameSize)
        try c.encode(pitchConfidenceThreshold,         forKey: .pitchConfidenceThreshold)
        try c.encode(defaultVocalVolume,        forKey: .defaultVocalVolume)
        try c.encode(defaultInstrumentalVolume, forKey: .defaultInstrumentalVolume)
        try c.encode(playbackRate,              forKey: .playbackRate)
        try c.encode(pitchShiftSemitones,       forKey: .pitchShiftSemitones)
        try c.encode(visualizer, forKey: .visualizer)
        try c.encode(gateEnabled, forKey: .gateEnabled)
        try c.encode(gateThreshold, forKey: .gateThreshold)
        try c.encode(gateRatio, forKey: .gateRatio)
        try c.encode(gateAttack, forKey: .gateAttack)
        try c.encode(gateRelease, forKey: .gateRelease)
        try c.encode(gatePreset, forKey: .gatePreset)
        try c.encode(eqPreset, forKey: .eqPreset)
        try c.encode(compressorPreset, forKey: .compressorPreset)
        try c.encode(tunerEnabled, forKey: .tunerEnabled)
        try c.encode(tunerKey, forKey: .tunerKey)
        try c.encode(tunerScale, forKey: .tunerScale)
        try c.encode(tunerAmount, forKey: .tunerAmount)
        try c.encode(tunerSpeed, forKey: .tunerSpeed)
        try c.encode(reverbMix,    forKey: .reverbMix)
        try c.encode(delayMix,      forKey: .delayMix)
        try c.encode(delayTime,     forKey: .delayTime)
        try c.encode(delayFeedback, forKey: .delayFeedback)
        try c.encode(delayMode,     forKey: .delayMode)
        try c.encode(eqEnabled,          forKey: .eqEnabled)
        try c.encode(compressorEnabled,  forKey: .compressorEnabled)
        try c.encode(delayEnabled,       forKey: .delayEnabled)
        try c.encode(reverbEnabled,      forKey: .reverbEnabled)
        try c.encode(compressorThreshold,  forKey: .compressorThreshold)
        try c.encode(compressorRatio,      forKey: .compressorRatio)
        try c.encode(compressorMakeupGain, forKey: .compressorMakeupGain)
        try c.encode(lowGain,      forKey: .lowGain)
        try c.encode(midGain,      forKey: .midGain)
        try c.encode(highGain,     forKey: .highGain)
    }

    private static func settingsURL() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let tonoDir = appSupport.appendingPathComponent("Tono", isDirectory: true)
        try? FileManager.default.createDirectory(at: tonoDir, withIntermediateDirectories: true)
        return tonoDir.appendingPathComponent("settings.json")
    }

    private func autosave() {
        pendingAutosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistSnapshot()
        }
        pendingAutosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveDebounceSeconds, execute: workItem)
    }

    private func persistSnapshot() {
        let url = Self.settingsURL()
        guard let data = try? JSONEncoder().encode(self) else { return }
        FileWriteDeduper.shared.writeIfChanged(
            data,
            to: url,
            key: Self.persistenceKey
        )
    }

    private static func sanitizedVisualizerIntensity(_ value: Double) -> Double {
        guard value.isFinite else { return 0.35 }
        return max(0.15, min(0.8, value))
    }

    private static func sanitizedVisualizerReadabilityScrim(_ value: Double) -> Double {
        guard value.isFinite else { return 0.42 }
        return max(0.20, min(0.85, value))
    }

    private static func sanitizedVisualizerSettings(_ settings: VisualizerSettings) -> VisualizerSettings {
        VisualizerSettings(
            isEnabled: settings.isEnabled,
            intensity: sanitizedVisualizerIntensity(settings.intensity),
            placement: settings.placement,
            style: settings.style,
            readabilityScrim: sanitizedVisualizerReadabilityScrim(settings.readabilityScrim)
        )
    }
}

final class FileWriteDeduper: @unchecked Sendable {
    static let shared = FileWriteDeduper()

    private struct Signature: Equatable {
        let byteCount: Int
        let hash: UInt64
    }

    private let queue = DispatchQueue(label: "com.tono.fileWriteDeduper", qos: .utility)
    private var lastWrittenSignatures: [String: Signature] = [:]

    func seedLastWrittenData(_ data: Data, forKey key: String) {
        let signature = Self.signature(for: data)
        queue.async { [self] in
            lastWrittenSignatures[key] = signature
        }
    }

    func writeIfChanged(_ data: Data, to url: URL, key: String) {
        let nextSignature = Self.signature(for: data)
        queue.async { [self] in
            guard lastWrittenSignatures[key] != nextSignature else { return }
            do {
                try data.write(to: url, options: .atomic)
                lastWrittenSignatures[key] = nextSignature
            } catch {
                // Best-effort persistence; ignore disk write errors to avoid UI regressions.
            }
        }
    }

    private static func signature(for data: Data) -> Signature {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Signature(byteCount: data.count, hash: hash)
    }
}
