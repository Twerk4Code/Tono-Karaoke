import AVFoundation
import AudioKit
import CoreAudio
import AudioToolbox
import AppKit

/// Manages dual-stem playback with truly independent vocal and instrumental volume.
///
/// Graph:
///   vocalPlayer → vocalMixer ──────────────────────────────┐
///                                                          ├→ mainMixer → engine output (→ selected output device)
///   instrumentalPlayer → instrumentalMixer ───────────────┘
///   mic (selected input device) → micMonoMixer → micEffects → micMonitorMixer → mainMixer
///
/// Device routing:
///   Output and input devices are set via kAudioOutputUnitProperty_CurrentDevice on the
///   engine's I/O audio units.  Call setOutputDevice(_:) / setInputDevice(_:) with a
///   CoreAudio AudioDeviceID at any time (engine restarts automatically as needed).
///
/// Volume is set on each stem's dedicated mixer node — no bleed possible.
@MainActor
final class AudioEngineManager: ObservableObject {
    private enum AudioRoutingError: LocalizedError {
        case outputAudioUnitUnavailable
        case noValidOutputDevice
        case setOutputDeviceFailed(OSStatus)
        case outputDeviceStillInvalid

        var errorDescription: String? {
            switch self {
            case .outputAudioUnitUnavailable:
                return "Output AudioUnit is unavailable."
            case .noValidOutputDevice:
                return "No valid output device is currently available."
            case .setOutputDeviceFailed(let status):
                return "Failed to set output device (OSStatus \(status))."
            case .outputDeviceStillInvalid:
                return "Output device is still invalid after fallback."
            }
        }
    }

    // MARK: - AudioKit Engine
    let engine = AudioEngine()

    // MARK: - Stem Players (separate nodes — CRITICAL: never share)
    // nonisolated(unsafe) because AudioKit players are called from the audio thread queue
    // and handle their own internal synchronization.
    nonisolated(unsafe) private let vocalPlayer = AudioPlayer()
    nonisolated(unsafe) private let instrumentalPlayer = AudioPlayer()

    // MARK: - TimePitch Nodes (playback speed without pitch change)
    // Inserted between players and mixers: player → timePitch → mixer.
    // NOTE: Feature 2 (Key Transposition) will set the `pitch` parameter on these nodes.
    // Initialized in init() after players are created.
    private var vocalTimePitch: TimePitch!
    private var instrumentalTimePitch: TimePitch!

    // MARK: - Dedicated Mixer Per Stem
    private let vocalMixer = Mixer()
    private let instrumentalMixer = Mixer()

    // MARK: - Main Output Mixer
    private let mainMixer = Mixer()
    /// Dedicated pass-through mixer for visualizer analysis tap.
    /// Keeps tap lifecycle isolated from the primary mix bus.
    private let visualizerTapMixer = Mixer()
    /// De-click guard: temporarily mute around hard stop/reset/re-route transitions.
    private var transitionMuteDepth = 0
    private var transitionMainMixerVolume: AUValue = 1.0
    /// Reserve one extra input bus on `mainMixer` for the mic monitor branch.
    /// Avoids late bus-array growth after the engine has already run once.
    private let mainMixerReservedInputBuses = 3

    // MARK: - Mic Path
    private(set) var mic: AudioEngine.InputNode?
    /// Forces the mic input to mono so a single-channel source (e.g. MOTU M2 left input)
    /// is centered in both ears instead of playing only on the left.
    private var micMonoMixer: Mixer?
    /// Effects chain applied to the live microphone signal.
    private(set) var micEffects: EffectsProcessor?
    /// Preferred source node for pitch tracking taps.
    /// Uses post-FX pre-tuner signal to avoid tap contention on micMonoMixer,
    /// where the mic spectrum analyzer also installs a tap.
    var pitchTrackingNode: Node? {
        if let effects = micEffects { return effects.pitchTrackingOutput }
        if let mono = micMonoMixer { return mono }
        if let input = mic { return input }
        return nil
    }
    /// Called whenever a fresh mic effects chain is created.
    var onMicEffectsReady: (@MainActor (EffectsProcessor) -> Void)?

    /// Controls whether the processed mic signal reaches the speakers (monitoring).
    /// Volume 0 = silent (PitchTap still works); volume 1 = full monitor.
    private var micMonitorMixer: Mixer?
    /// Post-FX vocal bus that provides explicit L/R channel control.
    private var micVocalBusMixer: Mixer?
    private var micVocalBusLeftMixer: Mixer?
    private var micVocalBusRightMixer: Mixer?
    /// Prevents concurrent mic graph builds (monitor + pitch can request setup together).
    private var isInitializingMicInput = false
    /// Coalesced setup callbacks executed once mic initialization finishes.
    private var pendingMicReadyCallbacks: [(@MainActor @Sendable () -> Void)] = []

    /// Whether mic monitoring (live playback through effects) is active.
    @Published var isMicMonitoring = false {
        didSet { micMonitorMixer?.volume = isMicMonitoring ? 1 : 0 }
    }
    /// Vocal monitor bus left gain (0...1.5). 1.0 = unity.
    @Published var micBusLeftGain: Double = 1.0 {
        didSet { applyMicVocalBusGains() }
    }
    /// Vocal monitor bus right gain (0...1.5). 1.0 = unity.
    @Published var micBusRightGain: Double = 1.0 {
        didSet { applyMicVocalBusGains() }
    }

    // MARK: - Published State
    @Published var engineIsRunning = false
    @Published var isMicrophoneAuthorized = false
    @Published var isRawMode = false
    @Published var currentBufferSize: UInt32 = 512
    @Published var vocalVolume: Double = 1.0 {
        didSet { vocalMixer.volume = AUValue(vocalVolume) }
    }
    @Published var instrumentalVolume: Double = 1.0 {
        didSet { instrumentalMixer.volume = AUValue(instrumentalVolume) }
    }

    /// Playback speed multiplier (0.5–2.0). Adjusts rate without changing pitch.
    var playbackRate: Double = 1.0 {
        didSet {
            let rate = AUValue(playbackRate)
            vocalTimePitch.rate = rate
            instrumentalTimePitch.rate = rate
            // Reset internal spectral buffers on every rate change.
            // AVAudioUnitTimePitch accumulates stale state when transitioning
            // between rates (especially back to 1.0), causing persistent distortion.
            (vocalTimePitch.avAudioNode as? AVAudioUnitTimePitch)?.reset()
            (instrumentalTimePitch.avAudioNode as? AVAudioUnitTimePitch)?.reset()
        }
    }

    /// Pitch shift in semitones (–6 to +6). Rate stays unchanged.
    var pitchShiftSemitones: Int = 0 {
        didSet {
            let cents = AUValue(pitchShiftSemitones) * 100
            vocalTimePitch.pitch = cents
            instrumentalTimePitch.pitch = cents
        }
    }

    // MARK: - Audio Thread Queue
    // AVAudioPlayerNode operations (play/pause/stop/seek) synchronize internally
    // with the audio render thread. This queue is also awaited by main-actor UI
    // calls (e.g. playbackSnapshot), so keep QoS at least userInitiated to avoid
    // Thread Performance Checker priority-inversion warnings.
    private let audioQueue = DispatchQueue(label: "com.tono.audioPlayer",
                                           qos: .userInitiated)

    // MARK: - Configuration-change callback
    /// Called after the engine successfully recovers from an AVAudioEngineConfigurationChange.
    /// AppState sets this to re-attach mic-dependent objects (e.g. PitchTap) after a reset.
    var onEngineRestarted: (@MainActor () -> Void)?
    /// Called after `setInputDevice` finishes rebuilding the mic path.
    /// Use this to re-apply the saved output device without triggering the
    /// full `onEngineRestarted` loop (which would call `setInputDevice` again).
    var onInputDeviceApplied: (@MainActor @Sendable () -> Void)?

    // MARK: - Playback completion callback
    /// Called on MainActor when the current song finishes playing naturally.
    /// AppState uses this to advance the queue.
    var onPlaybackFinished: (@Sendable @MainActor () -> Void)?

    // NotificationCenter observer token — retained so the listener stays alive.
    private var configChangeObserver: NSObjectProtocol?
    private var systemWillSleepObserver: NSObjectProtocol?
    private var systemDidWakeObserver: NSObjectProtocol?
    /// Prevent concurrent AVAudioEngineConfigurationChange recovery loops.
    private var isRecoveringFromConfigurationChange = false
    /// Prevent concurrent wake-recovery loops.
    private var isRecoveringFromSystemWake = false
    private var wasPlayingBeforeSystemSleep = false
    private var hadMicPathBeforeSystemSleep = false
    private enum DelayedWorkKey: Hashable {
        case micSpectrumTapRetry
        case bufferSizeRestart
        case inputDeviceRebuild
        case outputRouteRecovery
    }
    private var delayedWorkTasks: [DelayedWorkKey: Task<Void, Never>] = [:]

    // MARK: - Visualizer Analysis Tap
    private weak var visualizerAnalyzer: PlaybackVisualizerAnalyzer?
    private var visualizerTapInstalled = false
    private let visualizerTapBufferSize: AVAudioFrameCount = 512

    // MARK: - Mic Spectrum Tap
    private var micSpectrumTapInstalled = false
    private let micSpectrumTapBufferSize: AVAudioFrameCount = 1024
    private var micSpectrumTapBlock: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?

    /// Saved input device ID requested before the mic path was initialized.
    /// Applied automatically inside initializeMicInput() once the path is live.
    /// Use setPendingInputDevice(_:) to set this without touching engine.avEngine.inputNode.
    private(set) var pendingInputDeviceID: AudioDeviceID?

    private static var diagnosticsEnabled: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["TONO_AUDIO_DEBUG_LOGS"] == "1"
#else
        false
#endif
    }

    /// Queue an input device to be applied when the mic path initializes,
    /// WITHOUT touching engine.avEngine.inputNode (which would prematurely activate
    /// the HAL input hardware and emit CoreAudio device-ID-0 errors).
    func setPendingInputDevice(_ deviceID: AudioDeviceID) {
        pendingInputDeviceID = deviceID
    }

    // MARK: - Init
    init() {
        // Wire: vocalPlayer → vocalTimePitch → vocalMixer
        //       instrumentalPlayer → instrumentalTimePitch → instrumentalMixer
        vocalTimePitch = TimePitch(vocalPlayer, overlap: 32.0)
        instrumentalTimePitch = TimePitch(instrumentalPlayer, overlap: 32.0)
        vocalMixer.addInput(vocalTimePitch)
        instrumentalMixer.addInput(instrumentalTimePitch)

        // Stem playback stays dry. FX are mic-monitor-only.
        mainMixer.addInput(vocalMixer)
        mainMixer.addInput(instrumentalMixer)
        reserveMainMixerInputBusesIfNeeded()

        visualizerTapMixer.addInput(mainMixer)
        engine.output = visualizerTapMixer
        installPowerStateObservers()
    }

    deinit {
        MainActor.assumeIsolated {
            delayedWorkTasks.values.forEach { $0.cancel() }
            delayedWorkTasks.removeAll()

            if let observer = configChangeObserver {
                NotificationCenter.default.removeObserver(observer)
                configChangeObserver = nil
            }
            let center = NSWorkspace.shared.notificationCenter
            if let observer = systemWillSleepObserver {
                center.removeObserver(observer)
                systemWillSleepObserver = nil
            }
            if let observer = systemDidWakeObserver {
                center.removeObserver(observer)
                systemDidWakeObserver = nil
            }
        }
    }

    // MARK: - Visualizer

    func configureVisualizerAnalyzer(_ analyzer: PlaybackVisualizerAnalyzer) {
        visualizerAnalyzer = analyzer
        updateVisualizerTapState()
    }

    func refreshVisualizerTapState() {
        updateVisualizerTapState()
    }

    private func updateVisualizerTapState() {
        guard let analyzer = visualizerAnalyzer else {
            removeVisualizerTapIfNeeded()
            return
        }
        guard engineIsRunning else {
            removeVisualizerTapIfNeeded()
            return
        }
        if analyzer.isEnabled {
            installVisualizerTapIfNeeded()
        } else {
            removeVisualizerTapIfNeeded()
        }
    }

    private func installVisualizerTapIfNeeded() {
        guard !visualizerTapInstalled, let analyzer = visualizerAnalyzer else { return }
        guard engineIsRunning else { return }
        let tapNode = visualizerTapMixer.avAudioNode
        let outputFormat = tapNode.outputFormat(forBus: 0)
        guard outputFormat.sampleRate > 0, outputFormat.channelCount > 0 else {
#if DEBUG
            print("[Visualizer][Engine] Tap install skipped (invalid format sr=\(outputFormat.sampleRate) ch=\(outputFormat.channelCount))")
#endif
            return
        }
        let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak analyzer] buffer, time in
            Self.consumeVisualizerTap(analyzer: analyzer, buffer: buffer, time: time)
        }
        tapNode.installTap(onBus: 0, bufferSize: visualizerTapBufferSize, format: nil, block: tapHandler)
        visualizerTapInstalled = true
#if DEBUG
        print("[Visualizer][Engine] Tap installed on bus=0 bufferSize=\(visualizerTapBufferSize) sr=\(Int(outputFormat.sampleRate)) ch=\(outputFormat.channelCount)")
#endif
    }

    private func removeVisualizerTapIfNeeded() {
        guard visualizerTapInstalled else { return }
        let tapNode = visualizerTapMixer.avAudioNode
        tapNode.removeTap(onBus: 0)
        visualizerTapInstalled = false
#if DEBUG
        print("[Visualizer][Engine] Tap removed")
#endif
    }

    func installMicSpectrumTap(block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        micSpectrumTapBlock = block
        installMicSpectrumTapIfNeeded()
    }

    func removeMicSpectrumTap() {
        micSpectrumTapBlock = nil
        removeMicSpectrumTapIfNeeded()
    }

    private func installMicSpectrumTapIfNeeded() {
        guard !micSpectrumTapInstalled, let block = micSpectrumTapBlock else { return }
        guard let monoMixer = micMonoMixer else { return }
        let tapNode = monoMixer.avAudioNode
        // Skip if the node's format hasn't been negotiated yet (sampleRate == 0).
        // This can happen if called too soon after engine.start(); a retry is
        // scheduled below via installMicSpectrumTapWithRetry().
        let fmt = tapNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else {
            installMicSpectrumTapWithRetry()
            return
        }
        tapNode.installTap(onBus: 0, bufferSize: micSpectrumTapBufferSize, format: nil, block: block)
        micSpectrumTapInstalled = true
    }

    /// Schedules one deferred retry of `installMicSpectrumTapIfNeeded` to handle
    /// the case where the node format isn't ready immediately after engine start.
    private func installMicSpectrumTapWithRetry() {
        scheduleDelayedWork(.micSpectrumTapRetry, delayNanoseconds: 250_000_000) { [weak self] in
            self?.installMicSpectrumTapIfNeeded()
        }
    }

    private func removeMicSpectrumTapIfNeeded() {
        guard micSpectrumTapInstalled else { return }
        micMonoMixer?.avAudioNode.removeTap(onBus: 0)
        micSpectrumTapInstalled = false
    }

    private func stopEngineForGraphMutation() {
        beginTransitionMuteIfNeeded()
        removeVisualizerTapIfNeeded()
        engine.stop()
        engineIsRunning = false
    }

    private func beginTransitionMuteIfNeeded() {
        guard transitionMuteDepth == 0 else { return }
        transitionMainMixerVolume = mainMixer.volume
        mainMixer.volume = 0
        transitionMuteDepth = 1
    }

    private func endTransitionMuteIfNeeded() {
        guard transitionMuteDepth > 0 else { return }
        transitionMuteDepth = 0
        mainMixer.volume = transitionMainMixerVolume
    }

    private func reserveMainMixerInputBusesIfNeeded() {
        let allowed = mainMixer.resizeInputBussesArray(requiredSize: mainMixerReservedInputBuses)
        if allowed < mainMixerReservedInputBuses {
            logDebug(
                "[AudioEngineManager][DEBUG] mainMixer bus reservation limited: " +
                "requested=\(mainMixerReservedInputBuses) allowed=\(allowed)"
            )
        }
    }

    private func scheduleDelayedWork(
        _ key: DelayedWorkKey,
        delayNanoseconds: UInt64,
        operation: @escaping @MainActor () async -> Void
    ) {
        delayedWorkTasks[key]?.cancel()
        delayedWorkTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard let self, !Task.isCancelled else { return }
            await operation()
            self.delayedWorkTasks[key] = nil
        }
    }

    private func logDebug(_ message: @autoclosure () -> String) {
        guard Self.diagnosticsEnabled else { return }
        print(message())
    }

    private var isAppleSiliconBuild: Bool {
#if arch(arm64)
        true
#else
        false
#endif
    }

    /// AVAudioNode tap callbacks run on a CoreAudio realtime queue.
    /// Keep this callback nonisolated so it never inherits MainActor isolation.
    nonisolated private static func consumeVisualizerTap(
        analyzer: PlaybackVisualizerAnalyzer?,
        buffer: AVAudioPCMBuffer,
        time: AVAudioTime
    ) {
        analyzer?.consumeAudioBuffer(buffer, at: time)
    }

    // MARK: - Engine Lifecycle

    func start() throws {
        guard !engineIsRunning else { return }
        beginTransitionMuteIfNeeded()
        do {
            // Sync mMaxFramesPerSlice BEFORE starting so the graph is consistent.
            if syncMaxFramesPerSlice() {
                markTransientDSPStateInvalidated()
            }
            try ensureValidOutputRouteBeforeStart()
            try ensureValidInputRouteBeforeStart()
            prepareTransientDSPStateForEngineStart()
            debugLogRenderConfig("start(pre)")
            try engine.start()
            engineIsRunning = true
            // Read the actual hardware buffer size so currentBufferSize stays accurate
            if let deviceID = getCurrentOutputDeviceID(),
               let frames = AudioDeviceManager.currentBufferFrameSize(for: deviceID) {
                currentBufferSize = frames
            }
            debugLogRenderConfig("start(post)")
            installConfigurationChangeObserver()
            updateVisualizerTapState()
            endTransitionMuteIfNeeded()
        } catch {
            endTransitionMuteIfNeeded()
            throw error
        }
    }

    func stopEngine() {
        stopEngineForGraphMutation()
    }

    // MARK: - MaxFramesPerSlice Synchronization

    /// A safe upper-bound for mMaxFramesPerSlice across all AudioUnits in the graph.
    ///
    /// Rather than trying to match the exact hardware buffer size (which can change
    /// after the engine starts — e.g. MOTU M2 jumping from 480 to 512 when the HAL
    /// activates full-duplex I/O), we set a generous upper bound. The I/O unit will
    /// still render at whatever the hardware buffer actually is; it just won't exceed
    /// this value. This eliminates the race between reading the buffer size and the
    /// HAL renegotiating it.
    private let maxFramesUpperBound: UInt32 = 4096

    /// Set `maximumFramesToRender` on EVERY node in the AVAudioEngine graph
    /// to `maxFramesUpperBound` (4096).
    ///
    /// Uses the v3 `AUAudioUnit.maximumFramesToRender` API (bridged to the v2
    /// `kAudioUnitProperty_MaximumFramesPerSlice`) via `AVAudioNode.auAudioUnit`.
    /// This covers ALL node types — including `AVAudioPlayerNode`,
    /// `AVAudioMixerNode`, and `AVAudioSourceNode` — which are NOT `AVAudioUnit`
    /// subclasses and were previously skipped by the `as? AVAudioUnit` cast.
    ///
    /// MUST be called while the engine is stopped (before engine.start()).
    @discardableResult
    private func syncMaxFramesPerSlice() -> Bool {
        let avEngine = engine.avEngine
        let target = AUAudioFrameCount(maxFramesUpperBound)
        var reallocatedRenderResources = false

        for node in avEngine.attachedNodes {
            let auAudioUnit = node.auAudioUnit
            guard auAudioUnit.maximumFramesToRender != target else { continue }

            // The property cannot be changed while render resources are allocated.
            // Deallocate first, set, then re-allocate.
            let wasAllocated = auAudioUnit.renderResourcesAllocated
            if wasAllocated {
                reallocatedRenderResources = true
                auAudioUnit.deallocateRenderResources()
            }
            auAudioUnit.maximumFramesToRender = target
            if wasAllocated {
                try? auAudioUnit.allocateRenderResources()
            }
        }

        return reallocatedRenderResources
    }

    private func markTransientDSPStateInvalidated() {
        micEffects?.markRenderResourcesInvalidated()
    }

    private func prepareTransientDSPStateForEngineStart() {
        micEffects?.prepareForEngineStart()
    }

    /// Safely restart the engine with full resource deallocation.
    ///
    /// The sequence is: stop -> reset (deallocate render resources) ->
    /// set mMaxFramesPerSlice (fixed 4096 upper bound) -> start.
    ///
    /// avEngine.reset() is critical: without it, AVAudioEngine's internal AU
    /// nodes retain stale mMaxFramesPerSlice values from the previous session.
    private func safeRestartEngine(preferringOutputDevice preferredDeviceID: AudioDeviceID? = nil) throws {
        let avEngine = engine.avEngine
        beginTransitionMuteIfNeeded()
        do {
            removeVisualizerTapIfNeeded()
            removeMicSpectrumTapIfNeeded()
            if avEngine.isRunning {
                engine.stop()
            }
            engineIsRunning = false
            avEngine.reset()
            markTransientDSPStateInvalidated()
            if syncMaxFramesPerSlice() {
                markTransientDSPStateInvalidated()
            }
            // After reset the AUHAL clears its device pointer. Restore a known-good
            // previous device so ensureValidOutputRouteBeforeStart() sees a real device
            // rather than device=0 / SR=0 — which would cause -10875 on engine.start().
            if let preferredID = preferredDeviceID,
               preferredID != AudioDeviceID(kAudioObjectUnknown),
               let outputUnit = avEngine.outputNode.audioUnit {
                var devID = preferredID
                let err = AudioUnitSetProperty(
                    outputUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size))
                if err == noErr {
                    print("[AudioEngineManager] safeRestartEngine: restored preferred output device \(preferredID)")
                } else {
                    print("[AudioEngineManager] safeRestartEngine: could not restore preferred output device \(preferredID) (\(err)); falling through to ensureValidOutputRouteBeforeStart")
                }
            }
            try ensureValidOutputRouteBeforeStart()
            try ensureValidInputRouteBeforeStart()
            prepareTransientDSPStateForEngineStart()
            debugLogRenderConfig("safeRestart(pre)")
            try engine.start()
            engineIsRunning = true

            if let deviceID = getCurrentOutputDeviceID(),
               let frames = AudioDeviceManager.currentBufferFrameSize(for: deviceID) {
                currentBufferSize = frames
            }
            debugLogRenderConfig("safeRestart(post)")
            updateVisualizerTapState()
            installMicSpectrumTapIfNeeded()
            endTransitionMuteIfNeeded()
        } catch {
            endTransitionMuteIfNeeded()
            throw error
        }
    }

    /// Start the engine, retrying on `kAudioUnitErr_FailedInitialization` (-10875).
    ///
    /// -10875 fires when `engine.start()` is called while the CoreAudio HAL is still
    /// transitioning (common after sleep/wake or device plug/unplug). The graph and
    /// device routes are assumed to be valid; only the HAL readiness can be the issue.
    ///
    /// On each retry the engine is reset so stale render-resource allocations are flushed
    /// before the HAL is asked to reinitialize. Non-retryable errors propagate immediately.
    ///
    /// - Parameters:
    ///   - maxAttempts: Total start attempts before giving up (default 5).
    ///   - initialDelayMs: First retry delay in ms; each subsequent retry doubles (default 300).
    private func startEngineWithRetry(
        maxAttempts: Int = 5,
        initialDelayMs: Int = 300
    ) async throws {
        let failedInitDomain = "com.apple.coreaudio.avfaudio"
        let failedInitCode = -10875  // kAudioUnitErr_FailedInitialization
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                if attempt > 1 {
                    // Flush stale HAL render state before retrying.
                    engine.avEngine.reset()
                    markTransientDSPStateInvalidated()
                }
                if syncMaxFramesPerSlice() {
                    markTransientDSPStateInvalidated()
                }
                prepareTransientDSPStateForEngineStart()
                try engine.start()
                if attempt > 1 {
                    print("[AudioEngineManager] engine.start() succeeded on attempt \(attempt)/\(maxAttempts)")
                }
                return
            } catch let error as NSError
                  where error.domain == failedInitDomain && error.code == failedInitCode {
                lastError = error
                let delayMs = initialDelayMs * attempt  // progressive back-off: 300, 600, 900…
                print("[AudioEngineManager] engine.start() attempt \(attempt)/\(maxAttempts) failed with FailedInitialization (-10875); retrying in \(delayMs)ms")
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(delayMs))
                }
            } catch {
                throw error  // non-retryable error — propagate immediately
            }
        }
        throw lastError!
    }

    private func debugLogRenderConfig(_ context: String) {
        let avEngine = engine.avEngine
        let inputFormat = avEngine.inputNode.outputFormat(forBus: 0)
        let outputFormat = avEngine.outputNode.outputFormat(forBus: 0)
        let inputDeviceID = getCurrentInputDeviceID() ?? AudioDeviceID(kAudioObjectUnknown)
        let outputDeviceID = getCurrentOutputDeviceID() ?? AudioDeviceID(kAudioObjectUnknown)
        logDebug(
            "[AudioEngineManager][DEBUG] \(context) " +
            "inputDevice=\(inputDeviceID) " +
            "inputSR=\(Int(inputFormat.sampleRate)) " +
            "inputCh=\(inputFormat.channelCount) " +
            "outputDevice=\(outputDeviceID) " +
            "outputSR=\(Int(outputFormat.sampleRate)) " +
            "outputCh=\(outputFormat.channelCount) " +
            "buffer=\(currentBufferSize) " +
            "maxFrames=\(maxFramesUpperBound)"
        )
    }

    // MARK: - AVAudioEngineConfigurationChange Handling

    /// Subscribe to AVAudioEngineConfigurationChange so we detect when the OS tears
    /// down our I/O session due to a device plug/unplug or sample-rate change.
    /// Installing more than once is harmless — the guard prevents double-registration.
    private func installConfigurationChangeObserver() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine.avEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    private func installPowerStateObservers() {
        guard systemWillSleepObserver == nil, systemDidWakeObserver == nil else { return }
        let center = NSWorkspace.shared.notificationCenter

        systemWillSleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWillSleep()
            }
        }

        systemDidWakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemDidWake()
            }
        }
    }

    private func handleSystemWillSleep() {
        wasPlayingBeforeSystemSleep = isPlaying
        hadMicPathBeforeSystemSleep = (mic != nil)
        if wasPlayingBeforeSystemSleep {
            pause()
        }
        if engineIsRunning {
            stopEngineForGraphMutation()
        }
    }

    private func handleSystemDidWake() {
        guard !isRecoveringFromSystemWake else { return }
        isRecoveringFromSystemWake = true

        Task { @MainActor in
            defer { self.isRecoveringFromSystemWake = false }
            // Give the HAL adequate time to reinitialize after wake.
            // 350 ms proved too short on some hardware; 600 ms avoids premature -10875.
            try? await Task.sleep(for: .milliseconds(600))

            let shouldRestorePlayback = self.wasPlayingBeforeSystemSleep
            let shouldRebuildMic = self.hadMicPathBeforeSystemSleep || self.mic != nil
            self.wasPlayingBeforeSystemSleep = false
            self.hadMicPathBeforeSystemSleep = false

            do {
                if shouldRebuildMic {
                    self.removeMicSpectrumTapIfNeeded()
                    self.mic = nil
                    self.micMonoMixer = nil
                    self.micEffects = nil

                    self.micMonitorMixer = nil
                    self.micVocalBusMixer = nil
                    self.micVocalBusLeftMixer = nil
                    self.micVocalBusRightMixer = nil
                    self.mainMixer.removeAllInputs()
                    self.reserveMainMixerInputBusesIfNeeded()
                    self.mainMixer.addInput(self.vocalMixer)
                    self.mainMixer.addInput(self.instrumentalMixer)
                    let avEngine = self.engine.avEngine
                    avEngine.reset()
                    self.syncMaxFramesPerSlice()
                    self.initializeMicInput {
                        self.onEngineRestarted?()
                        if shouldRestorePlayback { self.play() }
                    }
                } else {
                    try self.safeRestartEngine()
                    self.onEngineRestarted?()
                    if shouldRestorePlayback { self.play() }
                }
            } catch {
                print("[AudioEngineManager] Recovery after system wake failed: \(error)")
            }
        }
    }

    /// Called whenever AVAudioEngine detects a hardware topology change (device
    /// plug/unplug, sample-rate change, etc.). The engine has already been stopped
    /// by AVFoundation at this point, so we just rebuild the graph and restart.
    private func handleConfigurationChange() {
        guard !isRecoveringFromConfigurationChange else { return }

        // AVAudioEngine can emit configuration-change notifications while the graph
        // remains running (for example, transient UI/focus changes). Restarting in
        // that case is unnecessary and can cause audible pops.
        let avEngine = engine.avEngine
        if avEngine.isRunning {
            engineIsRunning = true
            if let deviceID = getCurrentOutputDeviceID(),
               let frames = AudioDeviceManager.currentBufferFrameSize(for: deviceID) {
                currentBufferSize = frames
            }
            return
        }

        isRecoveringFromConfigurationChange = true

        // Engine is already stopped by AVFoundation; mark state accordingly.
        engineIsRunning = false

        Task { @MainActor in
            defer { self.isRecoveringFromConfigurationChange = false }

            // Stop any active players so their internal state is clean before teardown.
            await stopPlayersAndWait()

            // Taps are invalidated across hardware reconfiguration cycles. Remove now
            // and let restart paths re-install as needed.
            self.removeVisualizerTapIfNeeded()

            // If the mic path was active we must tear it down — the old InputNode
            // reference is invalid after a configuration change. Set to nil so
            // initializeMicInput() builds a fresh path below.
            let micWasActive = mic != nil
            if micWasActive {
                removeMicSpectrumTapIfNeeded()
                mic = nil
                micMonoMixer = nil
                micEffects = nil

                micMonitorMixer = nil
                micVocalBusMixer = nil
                micVocalBusLeftMixer = nil
                micVocalBusRightMixer = nil
                // Remove the stale mic branch from the main mixer so AVAudioEngine
                // doesn't try to render a disconnected node.
                // AudioKit's Mixer.removeAllInputs is the safest way to do this;
                // we re-add the two stem branches immediately after.
                mainMixer.removeAllInputs()
                reserveMainMixerInputBusesIfNeeded()
                mainMixer.addInput(vocalMixer)
                mainMixer.addInput(instrumentalMixer)
            }

            // Give the hardware a moment to finish reconfiguring before we restart.
            try? await Task.sleep(for: .milliseconds(200))
            do {
                if micWasActive {
                    // Let initializeMicInput handle the single engine start.
                    // Don't call safeRestartEngine() first — that would cause a
                    // redundant stop/start when initializeMicInput stops the engine
                    // again to attach mic nodes, making the mic icon flash.
                    // The engine is already stopped and reset() was called implicitly
                    // by safeRestartEngine's flow; here we just reset without starting.
                    let avEngine = self.engine.avEngine
                    avEngine.reset()
                    self.syncMaxFramesPerSlice()
                    self.initializeMicInput {
                        self.onEngineRestarted?()
                    }
                } else {
                    var recovered = false
                    var lastError: Error?
                    // Up to 5 attempts, 400 ms apart (total ~1.6 s window).
                    // safeRestartEngine() already calls avEngine.reset() each time so
                    // stale HAL state is flushed on every attempt.
                    for attempt in 1...5 {
                        do {
                            try self.safeRestartEngine()
                            self.onEngineRestarted?()
                            recovered = true
                            break
                        } catch {
                            lastError = error
                            print("[AudioEngineManager] Restart attempt \(attempt) failed: \(error)")
                            try? await Task.sleep(for: .milliseconds(400))
                        }
                    }
                    if !recovered, let lastError {
                        throw lastError
                    }
                }
            } catch {
                print("[AudioEngineManager] Restart after configuration change failed: \(error)")
            }
        }
    }

    // MARK: - Buffer Size

    /// Get the CoreAudio device ID currently driving the engine's output node.
    func getCurrentOutputDeviceID() -> AudioDeviceID? {
        let avEngine = engine.avEngine
        guard let outputUnit = avEngine.outputNode.audioUnit else { return nil }
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioUnitGetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard err == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Get the CoreAudio device ID currently driving the engine's input node.
    private func getCurrentInputDeviceID() -> AudioDeviceID? {
        let avEngine = engine.avEngine
        guard let inputUnit = avEngine.inputNode.audioUnit else { return nil }
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioUnitGetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard err == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Returns true if two CoreAudio device IDs represent the same physical hardware
    /// or if one is a sub-device of an aggregate containing the other.
    ///
    /// When the mic is active AVAudioEngine creates a full-duplex aggregate device
    /// (e.g. device 108) that wraps the standalone output device (e.g. device 74,
    /// "MacBook Speakers") and input device (e.g. device 81, "MacBook Microphone").
    /// CoreAudio lists all members of an aggregate as "related devices" on both the
    /// aggregate and each sub-device, so this bidirectional check catches the case
    /// where the user has "MacBook Speakers" saved as their preferred output but the
    /// engine is actually running on the AVAudioEngine-created aggregate.
    private func deviceIsRelated(_ a: AudioDeviceID, _ b: AudioDeviceID) -> Bool {
        guard a != b else { return true }
        func relatedIDs(of id: AudioDeviceID) -> [AudioDeviceID] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyRelatedDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr,
                  size > 0 else { return [] }
            let count = Int(size) / MemoryLayout<AudioDeviceID>.size
            var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &ids) == noErr else { return [] }
            return ids
        }
        return relatedIDs(of: a).contains(b) || relatedIDs(of: b).contains(a)
    }

    /// Change the hardware I/O buffer size.
    /// Stops the engine, applies the new size to ALL active devices (output and input),
    /// resets the graph so mMaxFramesPerSlice is re-negotiated, then restarts.
    /// Preserves playback state.
    func setBufferSize(_ frames: UInt32) {
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        stopEngineForGraphMutation()

        // Apply to the output device.
        if let deviceID = getCurrentOutputDeviceID() {
            AudioDeviceManager.setBufferFrameSize(frames, for: deviceID)
        }
        // Also apply to input device when mic is active.
        if mic != nil {
            let avEngine = engine.avEngine
            if let inputUnit = avEngine.inputNode.audioUnit {
                var devID: AudioDeviceID = kAudioObjectUnknown
                var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                if AudioUnitGetProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice,
                                        kAudioUnitScope_Global, 0, &devID, &size) == noErr,
                   devID != kAudioObjectUnknown {
                    AudioDeviceManager.setBufferFrameSize(frames, for: devID)
                }
            }
        }

        currentBufferSize = frames

        scheduleDelayedWork(.bufferSizeRestart, delayNanoseconds: 150_000_000) { [weak self] in
            guard let self else { return }
            do {
                try self.safeRestartEngine()
                if wasPlaying { self.play() }
            } catch {
                print("[AudioEngineManager] Restart after setBufferSize failed: \(error)")
            }
        }
    }

    // MARK: - Device Routing

    /// Route audio output to a specific CoreAudio device.
    /// Pass `kAudioObjectUnknown` (0) to revert to the system default.
    /// Stops the engine, swaps the device, then restarts with a full
    /// syncMaxFramesPerSlice() so the graph is consistent with the new device's
    /// buffer size.
    func setOutputDevice(_ deviceID: AudioDeviceID) {
        let wasRunning = engineIsRunning
        let requestingSystemDefault = (deviceID == kAudioObjectUnknown)
        let resolvedID: AudioDeviceID
        if requestingSystemDefault {
            let defaultOutput = getDefaultOutputDevice()
            guard defaultOutput != AudioDeviceID(kAudioObjectUnknown) else {
                print("[AudioEngineManager] setOutputDevice: failed to resolve default output device")
                return
            }
            resolvedID = defaultOutput
        } else {
            resolvedID = deviceID
        }

        guard deviceHasOutputChannels(resolvedID) else {
            print("[AudioEngineManager] setOutputDevice: device has no output channels (\(resolvedID))")
            return
        }

        // Skip if the requested device is already the current output device, OR if
        // it is a related device (e.g. a sub-device of the AVAudioEngine-created
        // full-duplex aggregate that is already routing audio to the same hardware).
        //
        // Example: user saves "MacBook Speakers" (device 74) as their preferred output.
        // When the mic is active, AVAudioEngine wraps device 74 + device 81 into an
        // aggregate (device 108). Setting device 74 explicitly on the AUHAL that is
        // already running on aggregate 108 fails with -10851. Since 74 is a sub-device
        // of 108, the aggregate already covers the requested output — skip the switch.
        if let currentOutputID = getCurrentOutputDeviceID(),
           currentOutputID == resolvedID || deviceIsRelated(currentOutputID, resolvedID) {
            return
        }

        let wasPlaying = isPlaying
        if wasPlaying { pause() }

        // Capture the current device BEFORE stopping — engine.stop() clears the
        // AUHAL device pointer to 0. We use this to restore a known-good state
        // if the switch to the new device fails entirely.
        let savedOutputDeviceID = getCurrentOutputDeviceID()

        if requestingSystemDefault {
            do {
                try safeRestartEngine()
                if wasPlaying { play() }
            } catch {
                print("[AudioEngineManager] Restart after clearing output override failed: \(error)")
                recoverAfterOutputRoutingFailure(
                    wasRunning: wasRunning,
                    wasPlaying: wasPlaying,
                    preferringOutputDevice: nil
                )
            }
            return
        }

        // Stop engine before changing the output device so the render thread
        // isn't pulling through nodes during the transition.
        if engineIsRunning {
            stopEngineForGraphMutation()
        }

        let avEngine = engine.avEngine
        // Reset to fully release the HAL device association before setting a new device.
        // Without this, the AUHAL retains the previous device's format expectations
        // (e.g. MOTU M2 at 48 kHz) and rejects the new device with -10851
        // (kAudioUnitErr_InvalidPropertyValue). setInputDevice() already does this;
        // setOutputDevice() must be consistent.
        avEngine.reset()
        syncMaxFramesPerSlice()

        guard let outputUnit = avEngine.outputNode.audioUnit else {
            print("[AudioEngineManager] Cannot get output AudioUnit")
            recoverAfterOutputRoutingFailure(
                wasRunning: wasRunning,
                wasPlaying: wasPlaying,
                preferringOutputDevice: requestingSystemDefault ? nil : savedOutputDeviceID
            )
            return
        }

        var devID = resolvedID
        let err = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if err != noErr {
            // The requested device may be stale (e.g. unplugged). Try one direct
            // fallback to the current system default instead of re-entering the
            // configuration-change recovery path.
            print("[AudioEngineManager] setOutputDevice error: \(err) requested=\(deviceID) resolved=\(resolvedID) — falling back to system default")
            let fallbackID = getDefaultOutputDevice()
            guard fallbackID != AudioDeviceID(kAudioObjectUnknown) else {
                print("[AudioEngineManager] setOutputDevice: no valid fallback output device")
                recoverAfterOutputRoutingFailure(
                    wasRunning: wasRunning,
                    wasPlaying: wasPlaying,
                    preferringOutputDevice: requestingSystemDefault ? nil : savedOutputDeviceID
                )
                return
            }
            if fallbackID == resolvedID {
                print("[AudioEngineManager] setOutputDevice fallback skipped: resolved device is already the system default (\(fallbackID))")
                recoverAfterOutputRoutingFailure(
                    wasRunning: wasRunning,
                    wasPlaying: wasPlaying,
                    preferringOutputDevice: nil
                )
                return
            }
            var fallbackDevID = fallbackID
            let fallbackErr = AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &fallbackDevID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard fallbackErr == noErr else {
                print("[AudioEngineManager] setOutputDevice fallback failed: \(fallbackErr)")
                recoverAfterOutputRoutingFailure(
                    wasRunning: wasRunning,
                    wasPlaying: wasPlaying,
                    preferringOutputDevice: requestingSystemDefault ? nil : savedOutputDeviceID
                )
                return
            }
        }

        // Restart with syncMaxFramesPerSlice so nodes are consistent with the
        // new output device.
        do {
            try safeRestartEngine()
            if wasPlaying { play() }
        } catch {
            print("[AudioEngineManager] Restart after setOutputDevice failed: \(error)")
            recoverAfterOutputRoutingFailure(
                wasRunning: wasRunning,
                wasPlaying: wasPlaying,
                preferringOutputDevice: requestingSystemDefault ? nil : savedOutputDeviceID
            )
        }
    }

    /// Route audio input from a specific CoreAudio device.
    /// Pass `kAudioObjectUnknown` (0) to revert to the system default.
    /// If the mic path is not yet initialised the device ID is saved and applied
    /// automatically when initializeMicInput() runs later.
    ///
    /// When the mic IS already live this tears down and rebuilds the entire mic graph
    /// so that AVAudioEngine can negotiate the correct sample rate with the new device
    /// (e.g. switching from MacBook mic at 44100 Hz to MOTU M2 at 48000 Hz).
    func setInputDevice(_ deviceID: AudioDeviceID) {
        // `kAudioObjectUnknown` means "System Default". On duplex interfaces
        // (e.g. MOTU M2), users typically expect default input to follow the
        // currently selected output device. Fall back to system default input.
        let resolvedID: AudioDeviceID
        if deviceID == AudioDeviceID(kAudioObjectUnknown) {
            if let outputID = getCurrentOutputDeviceID(), deviceHasInputChannels(outputID) {
                resolvedID = outputID
            } else {
                resolvedID = getDefaultInputDevice()
            }
        } else {
            resolvedID = deviceID
        }
        guard resolvedID != AudioDeviceID(kAudioObjectUnknown) else {
            print("[AudioEngineManager] setInputDevice: failed to resolve default input device")
            return
        }
        logDebug(
            "[AudioEngineManager][DEBUG] setInputDevice requested=\(deviceID) " +
            "resolved=\(resolvedID) micActive=\(mic != nil)"
        )

        if mic == nil,
           let currentInputID = getCurrentInputDeviceID(),
           currentInputID == resolvedID || deviceIsRelated(currentInputID, resolvedID) {
            pendingInputDeviceID = nil
            print("[AudioEngineManager] setInputDevice: mic path not active — input already on requested device (\(currentInputID))")
            return
        }

        // Always persist the requested device so initializeMicInput() can apply it.
        pendingInputDeviceID = resolvedID

        if isInitializingMicInput {
            logDebug("[AudioEngineManager][DEBUG] setInputDevice deferred while mic graph is initializing")
            return
        }

        // Rebuild immediately ONLY when the mic path is already live.
        // The engine can expose inputNode.audioUnit even when our mic chain
        // hasn't been created yet; using that as a proxy causes double init.
        guard mic != nil else {
            print("[AudioEngineManager] setInputDevice: mic path not active — device ID saved for later")
            return
        }

        // If the requested device is already the current input device, skip the
        // expensive teardown/rebuild cycle. This prevents onEngineRestarted from
        // redundantly cycling the engine after a configuration change.
        if let inputUnit = engine.avEngine.inputNode.audioUnit {
            var currentID: AudioDeviceID = kAudioObjectUnknown
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            if AudioUnitGetProperty(inputUnit, kAudioOutputUnitProperty_CurrentDevice,
                                    kAudioUnitScope_Global, 0, &currentID, &size) == noErr,
               currentID == resolvedID || deviceIsRelated(currentID, resolvedID) {
                pendingInputDeviceID = nil  // already applied
                return
            }
        }

        // The mic graph is live.  Changing to a device with a different sample rate
        // (e.g. MOTU M2 at 48 kHz) requires a full mic-path teardown and rebuild —
        // hot-swapping the AudioUnit while the graph is connected silently breaks
        // the input node's format negotiation.
        let wasPlaying = isPlaying
        if wasPlaying { pause() }

        // Tear down the mic graph exactly as handleConfigurationChange does.
        removeMicSpectrumTapIfNeeded()
        mic = nil
        micMonoMixer = nil
        micEffects = nil
        micMonitorMixer = nil
        micVocalBusMixer = nil
        micVocalBusLeftMixer = nil
        micVocalBusRightMixer = nil
        mainMixer.removeAllInputs()
        reserveMainMixerInputBusesIfNeeded()
        mainMixer.addInput(vocalMixer)
        mainMixer.addInput(instrumentalMixer)

        stopEngineForGraphMutation()

        // Apply the new device to the (now disconnected) input AudioUnit.
        let avEngine = engine.avEngine
        // Reset the engine to fully deallocate render resources so
        // mMaxFramesPerSlice is re-negotiated cleanly on next start.
        avEngine.reset()

        if let inputUnit = avEngine.inputNode.audioUnit {
            var devID = resolvedID
            let err = AudioUnitSetProperty(
                inputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if err != noErr {
                print("[AudioEngineManager] setInputDevice error: \(err)")
                // Clear pending so initializeMicInput doesn't re-try a bad ID.
                pendingInputDeviceID = nil
            } else {
                logDebug("[AudioEngineManager][DEBUG] setInputDevice applied to live path device=\(devID)")
            }
        }

        // The device has already been applied above — clear the pending ID so
        // initializeMicInput doesn't attempt a redundant second stop/restart cycle.
        pendingInputDeviceID = nil

        // Rebuild the mic graph via initializeMicInput, which handles the
        // engine stop → attach nodes → syncMaxFramesPerSlice → start cycle
        // in a single pass. Do NOT start the engine here — that would cause a
        // redundant stop/start when initializeMicInput immediately stops it
        // again to attach mic nodes, making the mic icon flash on/off.
        //
        // NOTE: We intentionally do NOT fire onEngineRestarted here. That
        // callback re-applies saved device selections, which would call
        // setInputDevice again and create an infinite loop. The device has
        // already been applied above — only the mic graph needs rebuilding.
        scheduleDelayedWork(.inputDeviceRebuild, delayNanoseconds: 200_000_000) { [weak self] in
            guard let self else { return }
            self.initializeMicInput {
                if wasPlaying { self.play() }
                // Re-apply the saved output device so monitoring routes correctly.
                // Cannot use onEngineRestarted here — it would call setInputDevice
                // again and create an infinite loop.
                self.onInputDeviceApplied?()
            }
        }
    }

    // MARK: - CoreAudio Helpers

    private func getDefaultOutputDevice() -> AudioDeviceID {
        var deviceID = kAudioObjectUnknown as AudioDeviceID
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )
        guard err == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown), deviceHasOutputChannels(deviceID) else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        return deviceID
    }

    private func getDefaultInputDevice() -> AudioDeviceID {
        var deviceID = kAudioObjectUnknown as AudioDeviceID
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )
        guard err == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown), deviceHasInputChannels(deviceID) else {
            return AudioDeviceID(kAudioObjectUnknown)
        }
        return deviceID
    }

    /// Best-effort recovery so a failed output-route change does not leave
    /// the app silent with a stopped engine.
    ///
    /// Uses `safeRestartEngine()` (which calls `ensureValidOutputRouteBeforeStart`)
    /// rather than `engine.start()` directly, so we never try to restart with
    /// device=0 / SR=0 / ch=0 — the state the output node lands in after a failed
    /// device-property set.
    private func recoverAfterOutputRoutingFailure(
        wasRunning: Bool,
        wasPlaying: Bool,
        preferringOutputDevice preferredDeviceID: AudioDeviceID? = nil
    ) {
        guard wasRunning else { return }
        // Brief delay: give the HAL a moment to finish any in-progress device
        // transition before we re-query and restart.
        scheduleDelayedWork(.outputRouteRecovery, delayNanoseconds: 200_000_000) { [weak self] in
            guard let self else { return }
            do {
                // Pass the previous device so safeRestartEngine can restore it
                // after avEngine.reset() clears the AUHAL device pointer.
                try self.safeRestartEngine(preferringOutputDevice: preferredDeviceID)
                if wasPlaying { self.play() }
            } catch {
                print("[AudioEngineManager] setOutputDevice recovery failed: \(error)")
            }
        }
    }

    /// Ensure output AudioUnit is bound to a valid concrete device before engine.start().
    /// Prevents AVAudioEngine from initializing with output format sampleRate/channels = 0.
    private func ensureValidOutputRouteBeforeStart() throws {
        let avEngine = engine.avEngine
        guard let outputUnit = avEngine.outputNode.audioUnit else {
            throw AudioRoutingError.outputAudioUnitUnavailable
        }

        var currentID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let getErr = AudioUnitGetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentID,
            &size
        )
        if getErr == noErr, currentID != AudioDeviceID(kAudioObjectUnknown), deviceHasOutputChannels(currentID) {
            return
        }

        let fallbackID = getDefaultOutputDevice()
        guard fallbackID != AudioDeviceID(kAudioObjectUnknown) else {
            throw AudioRoutingError.noValidOutputDevice
        }

        var devID = fallbackID
        let setErr = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setErr == noErr else {
            // Some HAL output units reject an explicit "set to current/default"
            // with InvalidPropertyValue even though the route remains usable.
            var postSetID: AudioDeviceID = kAudioObjectUnknown
            var postSetSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            let postSetErr = AudioUnitGetProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &postSetID,
                &postSetSize
            )
            if postSetErr == noErr,
               postSetID != AudioDeviceID(kAudioObjectUnknown),
               deviceHasOutputChannels(postSetID) {
                logDebug("[AudioEngineManager][DEBUG] ensureValidOutputRouteBeforeStart set failed (\(setErr)) but output route is valid (\(postSetID)); continuing")
                return
            }
            if setErr == kAudioUnitErr_InvalidPropertyValue {
                // Built-in / default routes can reject an explicit re-bind even when the
                // HAL can still attach them implicitly during engine.start().
                // Continue and let start/retry logic re-negotiate the default route.
                logDebug("[AudioEngineManager][DEBUG] ensureValidOutputRouteBeforeStart received InvalidPropertyValue for fallback device=\(fallbackID); continuing with implicit system-default binding")
                return
            }
            throw AudioRoutingError.setOutputDeviceFailed(setErr)
        }

        var verifiedID: AudioDeviceID = kAudioObjectUnknown
        size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let verifyErr = AudioUnitGetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &verifiedID,
            &size
        )
        guard verifyErr == noErr,
              verifiedID != AudioDeviceID(kAudioObjectUnknown),
              deviceHasOutputChannels(verifiedID) else {
            throw AudioRoutingError.outputDeviceStillInvalid
        }
        logDebug("[AudioEngineManager][DEBUG] ensureValidOutputRouteBeforeStart applied fallback output device=\(verifiedID)")
    }

    /// Ensure input AudioUnit is bound to a valid concrete input device before engine.start().
    private func ensureValidInputRouteBeforeStart() throws {
        guard mic != nil else { return }

        let avEngine = engine.avEngine
        guard let inputUnit = avEngine.inputNode.audioUnit else { return }

        var currentID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let getErr = AudioUnitGetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &currentID,
            &size
        )
        if getErr == noErr, currentID != AudioDeviceID(kAudioObjectUnknown), deviceHasInputChannels(currentID) {
            return
        }

        let fallbackID = getDefaultInputDevice()
        guard fallbackID != AudioDeviceID(kAudioObjectUnknown) else { return }

        var devID = fallbackID
        let setErr = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setErr == noErr else {
            print("[AudioEngineManager] ensureValidInputRouteBeforeStart set failed: \(setErr)")
            return
        }
        logDebug("[AudioEngineManager][DEBUG] ensureValidInputRouteBeforeStart applied fallback input device=\(devID)")
    }

    @discardableResult
    private func applyInputDeviceBeforeStart(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != AudioDeviceID(kAudioObjectUnknown),
              deviceHasInputChannels(deviceID),
              let inputUnit = engine.avEngine.inputNode.audioUnit else {
            return false
        }

        var devID = deviceID
        let err = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard err == noErr else {
            logDebug("[AudioEngineManager][DEBUG] initializeMicInput pre-start input apply failed device=\(deviceID) err=\(err)")
            return false
        }

        logDebug("[AudioEngineManager][DEBUG] initializeMicInput pre-start input applied device=\(deviceID)")
        return true
    }

    private func deviceHasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer) == noErr else {
            return false
        }

        let channels = UnsafeMutableAudioBufferListPointer(bufferListPointer).reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels > 0
    }

    private func deviceHasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer) == noErr else {
            return false
        }

        let channels = UnsafeMutableAudioBufferListPointer(bufferListPointer).reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels > 0
    }

    // MARK: - Microphone Setup

    /// Request mic permission without initializing the audio graph.
    /// Call early (e.g. on app launch) so the system dialog appears before the user needs the mic.
    func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        isMicrophoneAuthorized = (status == .authorized)
        guard status == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor in
                self?.isMicrophoneAuthorized = granted
            }
        }
    }

    /// Set up the microphone input and call `onReady` once it is available.
    /// Safe to call multiple times — no-ops if the mic is already initialized.
    func setupMicrophone(onReady: (@MainActor @Sendable () -> Void)? = nil) {
        let pendingID = pendingInputDeviceID ?? AudioDeviceID(kAudioObjectUnknown)
        logDebug(
            "[AudioEngineManager][DEBUG] setupMicrophone requested " +
            "micExists=\(mic != nil) " +
            "monitoring=\(isMicMonitoring) " +
            "pendingInput=\(pendingID)"
        )

        // Ensure a concrete input route is queued each time monitoring is requested.
        // This avoids depending on an implicit "default" that may have changed since launch.
        if mic == nil, pendingInputDeviceID == nil {
            if let outputID = getCurrentOutputDeviceID(), deviceHasInputChannels(outputID) {
                // Prefer matching output+input USB interfaces (e.g. MOTU M2)
                // when no explicit input is currently selected.
                setPendingInputDevice(outputID)
            } else {
                let defaultInputID = getDefaultInputDevice()
                if defaultInputID != AudioDeviceID(kAudioObjectUnknown) {
                    setPendingInputDevice(defaultInputID)
                }
            }
        }

        guard mic == nil else {
            onReady?()
            return
        }

        if let onReady {
            pendingMicReadyCallbacks.append(onReady)
        }
        if isInitializingMicInput {
            logDebug("[AudioEngineManager][DEBUG] setupMicrophone coalesced into active initialization")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            initializeMicInput()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.initializeMicInput()
                    } else {
                        self.isMicrophoneAuthorized = false
                        self.flushPendingMicReadyCallbacks()
                    }
                }
            }
        default:
            isMicrophoneAuthorized = false
            flushPendingMicReadyCallbacks()
        }
    }

    // MONITORING SNAPSHOT (2026-03-18):
    // Keep this initialization order stable unless a dedicated routing regression pass is run.
    // See Docs/MonitoringRoutingSnapshot.md for invariants and failure signatures.
    private func initializeMicInput(onReady: (@MainActor @Sendable () -> Void)? = nil) {
        if let onReady {
            pendingMicReadyCallbacks.append(onReady)
        }
        guard !isInitializingMicInput else {
            logDebug("[AudioEngineManager][DEBUG] initializeMicInput ignored (already initializing)")
            return
        }
        isInitializingMicInput = true

        let finishMicInitialization: @MainActor () -> Void = {
            self.isInitializingMicInput = false
            self.flushPendingMicReadyCallbacks()
        }

        // Capture playback state BEFORE stopping the engine — we restore it after restart.
        let wasPlaying = isPlaying
        let requestedPendingInputID = consumePendingInputDeviceRequest()
        let hadPendingInputRequest = requestedPendingInputID != nil
        if wasPlaying {
            pause()
        }

        // Always mutate the graph while stopped. Dynamic addInput() on a running
        // graph has caused AVAudioEngine assertions on some macOS/Apple Silicon routes.
        if engineIsRunning {
            stopEngineForGraphMutation()
            engine.avEngine.reset()
        }

        // Always rebuild from a known baseline to avoid duplicate/stale mic branches.
        removeMicSpectrumTapIfNeeded()
        mic = nil
        micMonoMixer = nil
        micEffects = nil
        micMonitorMixer = nil
        mainMixer.removeAllInputs()
        reserveMainMixerInputBusesIfNeeded()
        mainMixer.addInput(vocalMixer)
        mainMixer.addInput(instrumentalMixer)

        guard let input = engine.input else {
            print("[AudioEngineManager] engine.input is nil; microphone not available yet")
            // Try to restart so playback still works even without mic.
            do {
                try start()
            } catch {
                print("[AudioEngineManager] Engine restart failed: \(error)")
            }
            finishMicInitialization()
            return
        }
        mic = input
        isMicrophoneAuthorized = true

        if let requestedPendingInputID {
            _ = applyInputDeviceBeforeStart(requestedPendingInputID)
        }

        // Route mic through mono downmix → effects → vocal bus → monitor → main output.
        let mono = createMonoMixer(for: input)
        micMonoMixer = mono
        let effects = EffectsProcessor(input: mono)
        micEffects = effects
        onMicEffectsReady?(effects)
        let monitorSource: Node = effects.output

        let leftMixer = Mixer(monitorSource)
        let rightMixer = Mixer(monitorSource)
        micVocalBusLeftMixer = leftMixer
        micVocalBusRightMixer = rightMixer
        applyMicVocalBusGains()
        if let leftNode = leftMixer.avAudioNode as? AVAudioMixerNode {
            leftNode.pan = -1.0
        }
        if let rightNode = rightMixer.avAudioNode as? AVAudioMixerNode {
            rightNode.pan = 1.0
        }
        let vocalBus = Mixer(leftMixer, rightMixer)
        micVocalBusMixer = vocalBus
        let monitor = Mixer(vocalBus)
        monitor.volume = isMicMonitoring ? 1 : 0
        micMonitorMixer = monitor
        reserveMainMixerInputBusesIfNeeded()
        mainMixer.addInput(monitor)
        let inFmt = input.avAudioNode.outputFormat(forBus: 0)
        logDebug(
            "[AudioEngineManager][DEBUG] initializeMicInput " +
            "\(hadPendingInputRequest ? "pending" : "standard") path " +
            "input sr=\(Int(inFmt.sampleRate)) ch=\(inFmt.channelCount) " +
            "monoOut sr=\(Int(mono.outputFormat.sampleRate)) ch=\(mono.outputFormat.channelCount)"
        )
        effects.debugDumpNodeFormats(
            context: hadPendingInputRequest ? "pending-path(pre-start)" : "standard-path(pre-start)"
        )

        // Sync mMaxFramesPerSlice (fixed 4096 upper bound) on all nodes —
        // including the freshly created EffectsProcessor nodes.
        syncMaxFramesPerSlice()

        // Merge the engine-start and onReady deferral into a single Task so we can
        // await startEngineWithRetry() — which retries on kAudioUnitErr_FailedInitialization
        // (-10875) that fires when the HAL isn't ready yet (e.g. post-wake, device change).
        beginTransitionMuteIfNeeded()
        Task { @MainActor in
            do {
                self.debugLogRenderConfig(
                    hadPendingInputRequest
                        ? "initializeMicInput(pre-start, pending device)"
                        : "initializeMicInput(pre-start)"
                )
                try await self.startEngineWithRetry()
                self.engineIsRunning = true
                if let deviceID = self.getCurrentOutputDeviceID(),
                   let frames = AudioDeviceManager.currentBufferFrameSize(for: deviceID) {
                    self.currentBufferSize = frames
                }
                self.debugLogRenderConfig(
                    hadPendingInputRequest
                        ? "initializeMicInput(post-start, pending device)"
                        : "initializeMicInput(post-start)"
                )
                self.applyInputLeftToStereoDuplicationIfSupported()
                self.updateVisualizerTapState()
                self.installMicSpectrumTapIfNeeded()
                self.endTransitionMuteIfNeeded()
                if let pendingID = requestedPendingInputID {
                    if let currentInputID = self.getCurrentInputDeviceID(),
                       currentInputID == pendingID || self.deviceIsRelated(currentInputID, pendingID) {
                        self.logDebug("[AudioEngineManager][DEBUG] initializeMicInput: pending input already active (\(currentInputID))")
                        self.onInputDeviceApplied?()
                    } else {
                        self.logDebug("[AudioEngineManager][DEBUG] initializeMicInput: deferring pending input switch to live path (\(pendingID))")
                        self.setInputDevice(pendingID)
                    }
                }
                if wasPlaying { self.play() }
            } catch {
                self.endTransitionMuteIfNeeded()
                print("[AudioEngineManager] Failed to start engine with mic after retries: \(error)")
            }
            // Defer callbacks so AVAudioEngine finishes hardware reconfiguration
            // before PitchTap.start() is called.
            try? await Task.sleep(for: .milliseconds(150))
            finishMicInitialization()
        }
    }

    private func flushPendingMicReadyCallbacks() {
        guard !pendingMicReadyCallbacks.isEmpty else { return }
        let callbacks = pendingMicReadyCallbacks
        pendingMicReadyCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    private func applyMicVocalBusGains() {
        let left = AUValue(clampMicBusGain(micBusLeftGain))
        let right = AUValue(clampMicBusGain(micBusRightGain))
        micVocalBusLeftMixer?.volume = left
        micVocalBusRightMixer?.volume = right
    }

    private func clampMicBusGain(_ value: Double) -> Double {
        min(max(value, 0.0), 1.5)
    }

    /// Attempt to map left input channel to both channels on the input unit itself.
    /// This is safer than forcing mixer output formats and avoids -10868 format drift.
    private func applyInputLeftToStereoDuplicationIfSupported() {
        guard let inputUnit = engine.avEngine.inputNode.audioUnit else { return }
        var channelMap: [Int32] = [0, 0]
        let size = UInt32(channelMap.count * MemoryLayout<Int32>.size)

        // AUHAL input is commonly exposed on output scope / element 1.
        let primary = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Output,
            1,
            &channelMap,
            size
        )
        if primary == noErr {
            logDebug("[AudioEngineManager][DEBUG] input channel map applied on scope=output element=1 [0,0]")
            return
        }

        // Fallback for devices exposing mapping on element 0.
        let fallback = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_ChannelMap,
            kAudioUnitScope_Output,
            0,
            &channelMap,
            size
        )
        if fallback == noErr {
            logDebug("[AudioEngineManager][DEBUG] input channel map applied on scope=output element=0 [0,0]")
        } else {
            logDebug("[AudioEngineManager][DEBUG] input channel map unsupported primary=\(primary) fallback=\(fallback)")
        }
    }

    /// Consume and clear a queued pending input device request for mic setup.
    private func consumePendingInputDeviceRequest() -> AudioDeviceID? {
        guard let pendingID = pendingInputDeviceID,
              pendingID != AudioDeviceID(kAudioObjectUnknown) else {
            pendingInputDeviceID = nil
            return nil
        }
        pendingInputDeviceID = nil
        logDebug("[AudioEngineManager][DEBUG] initializeMicInput pending device=\(pendingID)")
        return pendingID
    }

    // MARK: - Mono Downmix Helper

    /// Create a Mixer that forces its output to mono so a single-channel mic input
    /// (e.g. left-only from an audio interface) gets centered in both ears.
    /// AVAudioEngine automatically up-mixes mono → stereo at the next stereo node.
    private func createMonoMixer(for input: Node) -> Mixer {
        let mono = Mixer(input)
        // Do not force outputFormat here. On some routes this negotiates to 44.1 kHz
        // while the graph is at 48 kHz, causing AVAudioEngine start failure (-10868).
        // Channel duplication must be handled downstream without altering startup formats.
        return mono
    }

    // MARK: - Stem Loading

    /// Load both stems for a song. Call after vocal separation completes.
    func loadStems(vocalURL: URL, instrumentalURL: URL) throws {
        let vocalFile = try AVAudioFile(forReading: vocalURL)
        let instrumentalFile = try AVAudioFile(forReading: instrumentalURL)
        var loadError: Error?

        audioQueue.sync {
            // Force a clean transport state before replacing loaded files.
            self.vocalPlayer.stop()
            self.instrumentalPlayer.stop()
            do {
                try self.vocalPlayer.load(file: vocalFile, buffered: false)
                try self.instrumentalPlayer.load(file: instrumentalFile, buffered: false)
            } catch {
                loadError = error
            }
            // Use instrumentalPlayer as the authoritative completion source
            // (both stems have matching duration from the same source file).
            self.instrumentalPlayer.completionHandler = { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.onPlaybackFinished?() }
            }
        }

        if let loadError {
            throw loadError
        }
        isRawMode = false
        updateVisualizerTapState()
    }

    /// Load a raw (non-separated) audio file into the instrumental player.
    /// The vocal player is left empty; all transport operations use instrumental only.
    func loadRawSong(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        var loadError: Error?

        audioQueue.sync {
            // Stop both players to prevent stale vocal playback state from leaking.
            self.vocalPlayer.stop()
            self.instrumentalPlayer.stop()
            do {
                try self.instrumentalPlayer.load(file: file, buffered: false)
            } catch {
                loadError = error
            }
            self.instrumentalPlayer.completionHandler = { [weak self] in
                guard let self else { return }
                Task { @MainActor in self.onPlaybackFinished?() }
            }
        }

        if let loadError {
            throw loadError
        }
        isRawMode = true
        updateVisualizerTapState()
    }

    // MARK: - Transport

    func play() {
        if !engineIsRunning {
            // Engine is mid-restart (e.g. device switch). Start it now so playback
            // doesn't silently fail with "engine must be running".
            do {
                try start()
            } catch {
                print("[AudioEngineManager] play(): engine start failed: \(error)")
                return
            }
        }
        updateVisualizerTapState()
        let raw = isRawMode
        audioQueue.async {
            if !raw { self.vocalPlayer.play() }
            self.instrumentalPlayer.play()
        }
    }

    func pause() {
        let raw = isRawMode
        audioQueue.async {
            if !raw { self.vocalPlayer.pause() }
            self.instrumentalPlayer.pause()
        }
    }

    func stop() { stopPlayback() }

    private func stopPlayback() {
        audioQueue.async {
            self.vocalPlayer.stop()
            self.instrumentalPlayer.stop()
        }
    }

    /// Stop both players and wait for completion.
    /// Use this before loading a different song to avoid stem-state races.
    func stopAndWait() {
        audioQueue.sync {
            self.vocalPlayer.stop()
            self.instrumentalPlayer.stop()
        }
    }

    private func stopPlayersAndWait() async {
        await withCheckedContinuation { continuation in
            audioQueue.async {
                self.vocalPlayer.stop()
                self.instrumentalPlayer.stop()
                continuation.resume()
            }
        }
    }

    struct PlaybackSnapshot: Sendable {
        let isPlaying: Bool
        let currentTime: TimeInterval
        let duration: TimeInterval
    }

    func playbackSnapshot() async -> PlaybackSnapshot {
        let raw = isRawMode
        return await withCheckedContinuation { continuation in
            audioQueue.async {
                let isPlaying = raw
                    ? self.instrumentalPlayer.isPlaying
                    : (self.vocalPlayer.isPlaying || self.instrumentalPlayer.isPlaying)
                let currentTime = raw ? self.instrumentalPlayer.currentTime : self.vocalPlayer.currentTime
                let duration = raw ? self.instrumentalPlayer.duration : self.vocalPlayer.duration
                continuation.resume(returning: PlaybackSnapshot(
                    isPlaying: isPlaying,
                    currentTime: currentTime,
                    duration: duration
                ))
            }
        }
    }

    var isPlaying: Bool {
        isRawMode ? instrumentalPlayer.isPlaying : (vocalPlayer.isPlaying || instrumentalPlayer.isPlaying)
    }

    // MARK: - Seek

    func seek(to time: TimeInterval) {
        let raw = isRawMode
        audioQueue.async {
            let wasPlaying = raw
                ? self.instrumentalPlayer.isPlaying
                : (self.vocalPlayer.isPlaying || self.instrumentalPlayer.isPlaying)

            // AudioKit's seek(time:) is relative and performs its own stop/schedule/play.
            // Avoid wrapping it in extra stop/play calls to reduce internal lock contention.
            if !raw {
                let vocalDelta = time - self.vocalPlayer.currentTime
                if abs(vocalDelta) > 0.001 {
                    self.vocalPlayer.seek(time: vocalDelta)
                }
            }

            let instrumentalDelta = time - self.instrumentalPlayer.currentTime
            if abs(instrumentalDelta) > 0.001 {
                self.instrumentalPlayer.seek(time: instrumentalDelta)
            }

            // seek(time:) leaves the player in playing state; restore paused state if needed.
            if !wasPlaying {
                if !raw { self.vocalPlayer.pause() }
                self.instrumentalPlayer.pause()
            }
        }
    }

    var currentTime: TimeInterval {
        isRawMode ? instrumentalPlayer.currentTime : vocalPlayer.currentTime
    }

    var duration: TimeInterval {
        isRawMode ? instrumentalPlayer.duration : vocalPlayer.duration
    }
}
