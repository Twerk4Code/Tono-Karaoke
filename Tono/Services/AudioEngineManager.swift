import AVFoundation
import AudioKit
import CoreAudio
import AudioToolbox

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

    // MARK: - Mic Path
    private(set) var mic: AudioEngine.InputNode?
    /// Forces the mic input to mono so a single-channel source (e.g. MOTU M2 left input)
    /// is centered in both ears instead of playing only on the left.
    private var micMonoMixer: Mixer?
    /// Effects chain applied to the live microphone signal.
    private(set) var micEffects: EffectsProcessor?
    /// Called whenever a fresh mic effects chain is created.
    var onMicEffectsReady: (@MainActor (EffectsProcessor) -> Void)?
    /// Controls whether the processed mic signal reaches the speakers (monitoring).
    /// Volume 0 = silent (PitchTap still works); volume 1 = full monitor.
    private var micMonitorMixer: Mixer?

    /// Whether mic monitoring (live playback through effects) is active.
    @Published var isMicMonitoring = false {
        didSet { micMonitorMixer?.volume = isMicMonitoring ? 1 : 0 }
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

    // NotificationCenter observer token — retained so the listener stays alive.
    private var configChangeObserver: NSObjectProtocol?
    /// Prevent concurrent AVAudioEngineConfigurationChange recovery loops.
    private var isRecoveringFromConfigurationChange = false

    // MARK: - Visualizer Analysis Tap
    private weak var visualizerAnalyzer: PlaybackVisualizerAnalyzer?
    private var visualizerTapInstalled = false
    private let visualizerTapBufferSize: AVAudioFrameCount = 512

    /// Saved input device ID requested before the mic path was initialized.
    /// Applied automatically inside initializeMicInput() once the path is live.
    /// Use setPendingInputDevice(_:) to set this without touching engine.avEngine.inputNode.
    private(set) var pendingInputDeviceID: AudioDeviceID?

    /// Queue an input device to be applied when the mic path initializes,
    /// WITHOUT touching engine.avEngine.inputNode (which would prematurely activate
    /// the HAL input hardware and emit CoreAudio device-ID-0 errors).
    func setPendingInputDevice(_ deviceID: AudioDeviceID) {
        pendingInputDeviceID = deviceID
    }

    // MARK: - Init
    init() {
        // Wire stem players into their own mixers
        vocalMixer.addInput(vocalPlayer)
        instrumentalMixer.addInput(instrumentalPlayer)

        // Stem playback stays dry. FX are mic-monitor-only.
        mainMixer.addInput(vocalMixer)
        mainMixer.addInput(instrumentalMixer)

        visualizerTapMixer.addInput(mainMixer)
        engine.output = visualizerTapMixer
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
            syncMaxFramesPerSlice()
            try ensureValidOutputRouteBeforeStart()
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
    private func syncMaxFramesPerSlice() {
        let avEngine = engine.avEngine
        let target = AUAudioFrameCount(maxFramesUpperBound)

        for node in avEngine.attachedNodes {
            let auAudioUnit = node.auAudioUnit
            guard auAudioUnit.maximumFramesToRender != target else { continue }

            // The property cannot be changed while render resources are allocated.
            // Deallocate first, set, then re-allocate.
            let wasAllocated = auAudioUnit.renderResourcesAllocated
            if wasAllocated { auAudioUnit.deallocateRenderResources() }
            auAudioUnit.maximumFramesToRender = target
            if wasAllocated {
                try? auAudioUnit.allocateRenderResources()
            }
        }
    }

    /// Safely restart the engine with full resource deallocation.
    ///
    /// The sequence is: stop -> reset (deallocate render resources) ->
    /// set mMaxFramesPerSlice (fixed 4096 upper bound) -> start.
    ///
    /// avEngine.reset() is critical: without it, AVAudioEngine's internal AU
    /// nodes retain stale mMaxFramesPerSlice values from the previous session.
    private func safeRestartEngine() throws {
        let avEngine = engine.avEngine
        beginTransitionMuteIfNeeded()
        do {
            removeVisualizerTapIfNeeded()
            if avEngine.isRunning {
                engine.stop()
            }
            engineIsRunning = false
            avEngine.reset()
            syncMaxFramesPerSlice()
            try ensureValidOutputRouteBeforeStart()
            debugLogRenderConfig("safeRestart(pre)")
            try engine.start()
            engineIsRunning = true

            if let deviceID = getCurrentOutputDeviceID(),
               let frames = AudioDeviceManager.currentBufferFrameSize(for: deviceID) {
                currentBufferSize = frames
            }
            debugLogRenderConfig("safeRestart(post)")
            updateVisualizerTapState()
            endTransitionMuteIfNeeded()
        } catch {
            endTransitionMuteIfNeeded()
            throw error
        }
    }

    private func debugLogRenderConfig(_ context: String) {
        let avEngine = engine.avEngine
        let inputFormat = avEngine.inputNode.outputFormat(forBus: 0)
        let outputFormat = avEngine.outputNode.outputFormat(forBus: 0)
        let inputDeviceID = getCurrentInputDeviceID() ?? AudioDeviceID(kAudioObjectUnknown)
        let outputDeviceID = getCurrentOutputDeviceID() ?? AudioDeviceID(kAudioObjectUnknown)
        print(
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
                mic = nil
                micMonoMixer = nil
                micEffects = nil
                micMonitorMixer = nil
                // Remove the stale mic branch from the main mixer so AVAudioEngine
                // doesn't try to render a disconnected node.
                // AudioKit's Mixer.removeAllInputs is the safest way to do this;
                // we re-add the two stem branches immediately after.
                mainMixer.removeAllInputs()
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
                    for attempt in 1...3 {
                        do {
                            try self.safeRestartEngine()
                            self.onEngineRestarted?()
                            recovered = true
                            break
                        } catch {
                            lastError = error
                            print("[AudioEngineManager] Restart attempt \(attempt) failed: \(error)")
                            try? await Task.sleep(for: .milliseconds(250))
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

        Task { @MainActor in
            // Wait for the hardware to acknowledge the new buffer size.
            try? await Task.sleep(for: .milliseconds(150))
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
        let resolvedID: AudioDeviceID
        if deviceID == kAudioObjectUnknown {
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

        // Skip if the requested device is already the current output device.
        // Prevents redundant engine cycling when onEngineRestarted re-applies
        // the saved device after a configuration change.
        if let currentOutputID = getCurrentOutputDeviceID(), currentOutputID == resolvedID {
            return
        }

        let wasPlaying = isPlaying
        if wasPlaying { pause() }

        // Stop engine before changing the output device so the render thread
        // isn't pulling through nodes during the transition.
        if engineIsRunning {
            stopEngineForGraphMutation()
        }

        let avEngine = engine.avEngine
        guard let outputUnit = avEngine.outputNode.audioUnit else {
            print("[AudioEngineManager] Cannot get output AudioUnit")
            recoverAfterOutputRoutingFailure(wasRunning: wasRunning, wasPlaying: wasPlaying)
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
                recoverAfterOutputRoutingFailure(wasRunning: wasRunning, wasPlaying: wasPlaying)
                return
            }
            if fallbackID == resolvedID {
                print("[AudioEngineManager] setOutputDevice fallback skipped: resolved device is already the system default (\(fallbackID))")
                recoverAfterOutputRoutingFailure(wasRunning: wasRunning, wasPlaying: wasPlaying)
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
                recoverAfterOutputRoutingFailure(wasRunning: wasRunning, wasPlaying: wasPlaying)
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
            recoverAfterOutputRoutingFailure(wasRunning: wasRunning, wasPlaying: wasPlaying)
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
        print(
            "[AudioEngineManager][DEBUG] setInputDevice requested=\(deviceID) " +
            "resolved=\(resolvedID) micActive=\(mic != nil)"
        )

        // Always persist the requested device so initializeMicInput() can apply it.
        pendingInputDeviceID = resolvedID

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
               currentID == resolvedID {
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
        mic = nil
        micMonoMixer = nil
        micEffects = nil
        micMonitorMixer = nil
        mainMixer.removeAllInputs()
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
                print("[AudioEngineManager][DEBUG] setInputDevice applied to live path device=\(devID)")
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
        Task { @MainActor in
            // Wait for the hardware to acknowledge the buffer size change.
            try? await Task.sleep(for: .milliseconds(200))
            self.initializeMicInput {
                if wasPlaying { self.play() }
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
    private func recoverAfterOutputRoutingFailure(wasRunning: Bool, wasPlaying: Bool) {
        guard wasRunning else { return }
        beginTransitionMuteIfNeeded()
        do {
            syncMaxFramesPerSlice()
            debugLogRenderConfig("setOutputDevice(recover, pre)")
            try engine.start()
            engineIsRunning = true
            if let deviceID = getCurrentOutputDeviceID(),
               let frames = AudioDeviceManager.currentBufferFrameSize(for: deviceID) {
                currentBufferSize = frames
            }
            debugLogRenderConfig("setOutputDevice(recover, post)")
            updateVisualizerTapState()
            endTransitionMuteIfNeeded()
            if wasPlaying { play() }
        } catch {
            endTransitionMuteIfNeeded()
            print("[AudioEngineManager] setOutputDevice recovery failed: \(error)")
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
                print("[AudioEngineManager][DEBUG] ensureValidOutputRouteBeforeStart set failed (\(setErr)) but output route is valid (\(postSetID)); continuing")
                return
            }
            if setErr == kAudioUnitErr_InvalidPropertyValue {
                print("[AudioEngineManager][DEBUG] ensureValidOutputRouteBeforeStart received InvalidPropertyValue for fallback output device=\(fallbackID); continuing with AVAudioEngine-selected route")
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
        print("[AudioEngineManager][DEBUG] ensureValidOutputRouteBeforeStart applied fallback output device=\(verifiedID)")
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
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    /// Set up the microphone input and call `onReady` once it is available.
    /// Safe to call multiple times — no-ops if the mic is already initialized.
    func setupMicrophone(onReady: (@MainActor @Sendable () -> Void)? = nil) {
        let pendingID = pendingInputDeviceID ?? AudioDeviceID(kAudioObjectUnknown)
        print(
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
                setInputDevice(outputID)
            } else {
                setInputDevice(AudioDeviceID(kAudioObjectUnknown))
            }
        }

        guard mic == nil else {
            onReady?()
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            initializeMicInput(onReady: onReady)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.initializeMicInput(onReady: onReady)
                    } else {
                        self.isMicrophoneAuthorized = false
                    }
                }
            }
        default:
            isMicrophoneAuthorized = false
        }
    }

    private func initializeMicInput(onReady: (@MainActor @Sendable () -> Void)? = nil) {
        // Capture playback state BEFORE stopping the engine — we restore it after restart.
        let wasPlaying = isPlaying

        // If a specific input device was requested (e.g. MOTU M2 chosen in Settings
        // before the mic path was live), apply it BEFORE accessing engine.input.
        //
        // CRITICAL FIX: The old code accessed engine.input first (which connects the
        // inputNode using the DEFAULT device), started the engine, then changed the
        // device and restarted. This left stale mMaxFramesPerSlice values from the
        // default device's buffer size (e.g. 512) on internal AU nodes, even after
        // the device was changed to one with a different buffer (e.g. MOTU M2 at 480).
        //
        // The fix: apply the pending device to the input AudioUnit BEFORE the engine
        // starts, so AVAudioEngine negotiates everything against the correct device.
        if let pendingID = pendingInputDeviceID, pendingID != kAudioObjectUnknown {
            pendingInputDeviceID = nil   // consume so we don't re-apply on next init
            print("[AudioEngineManager][DEBUG] initializeMicInput pending device=\(pendingID)")

            // Stop the engine and reset so the input node gets a clean slate.
            let wasRunning = engineIsRunning
            if wasRunning {
                if wasPlaying { pause() }
                stopEngineForGraphMutation()
            }
            let avEngine = engine.avEngine
            avEngine.reset()

            // Apply the pending device BEFORE connecting engine.input whenever possible.
            // This avoids connecting AudioKit's input mixer against the wrong hardware format.
            var appliedPendingDevice = false
            if let inputUnit = avEngine.inputNode.audioUnit {
                var devID = pendingID
                let err = AudioUnitSetProperty(
                    inputUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if err != noErr {
                    print("[AudioEngineManager] initializeMicInput: apply pendingInputDevice error: \(err)")
                } else {
                    appliedPendingDevice = true
                    print("[AudioEngineManager][DEBUG] initializeMicInput: applied pending input device before engine.input (\(devID))")
                }
            } else {
                print("[AudioEngineManager][DEBUG] initializeMicInput: inputUnit unavailable before engine.input")
            }

            // Access engine.input to trigger inputNode connection (AudioKit lazy-connects).
            guard let input = engine.input else {
                print("[AudioEngineManager] engine.input is nil; microphone not available yet")
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(150))
                    onReady?()
                }
                return
            }

            // Fallback: if the input unit wasn't available pre-connect, apply now.
            if !appliedPendingDevice, let inputUnit = avEngine.inputNode.audioUnit {
                var devID = pendingID
                let err = AudioUnitSetProperty(
                    inputUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if err != noErr {
                    print("[AudioEngineManager] initializeMicInput: apply pendingInputDevice (post-connect) error: \(err)")
                } else {
                    print("[AudioEngineManager][DEBUG] initializeMicInput: applied pending input device after engine.input (\(devID))")
                }
            } else if !appliedPendingDevice {
                print("[AudioEngineManager][DEBUG] initializeMicInput: inputUnit unavailable after engine.input")
            }

            // Build the mic effects chain.
            // Force the mic input to mono so a single-channel source (e.g. left-only
            // input on MOTU M2) is centered in both ears when up-mixed to stereo.
            mic = input
            isMicrophoneAuthorized = true
            let mono = createMonoMixer(for: input)
            micMonoMixer = mono
            let fx = EffectsProcessor(input: mono)
            micEffects = fx
            onMicEffectsReady?(fx)
            let monitor = Mixer(fx.output)
            monitor.volume = isMicMonitoring ? 1 : 0
            micMonitorMixer = monitor
            mainMixer.addInput(monitor)
            let inFmt = input.avAudioNode.outputFormat(forBus: 0)
            print(
                "[AudioEngineManager][DEBUG] initializeMicInput pending path " +
                "input sr=\(Int(inFmt.sampleRate)) ch=\(inFmt.channelCount) " +
                "monoOut sr=\(Int(mono.outputFormat.sampleRate)) ch=\(mono.outputFormat.channelCount)"
            )
            fx.debugDumpNodeFormats(context: "pending-path(pre-start)")

            // Sync mMaxFramesPerSlice on all nodes NOW — including the freshly created
            // EffectsProcessor nodes that were born with AudioKit's default value (512).
            // This runs synchronously before the async gap, so nodes are consistent
            // before engine.start() is called in the Task below.
            syncMaxFramesPerSlice()

            // Start the engine with correct mMaxFramesPerSlice from the start.
            Task { @MainActor in
                // Wait for the hardware to acknowledge buffer size changes.
                try? await Task.sleep(for: .milliseconds(200))
                self.beginTransitionMuteIfNeeded()
                do {
                    self.syncMaxFramesPerSlice()  // re-sync after hardware settles
                    self.debugLogRenderConfig("initializeMicInput(pre-start, pending device)")
                    self.micEffects?.debugDumpNodeFormats(context: "pending-path(pre-start, post-sync)")
                    try self.engine.start()
                    self.engineIsRunning = true
                    if let deviceID = self.getCurrentOutputDeviceID(),
                       let frames = AudioDeviceManager.currentBufferFrameSize(for: deviceID) {
                        self.currentBufferSize = frames
                    }
                    self.debugLogRenderConfig("initializeMicInput(post-start, pending device)")
                    self.updateVisualizerTapState()
                    self.endTransitionMuteIfNeeded()
                    if wasPlaying { self.play() }
                } catch {
                    self.endTransitionMuteIfNeeded()
                    print("[AudioEngineManager] Restart after applying pending input device failed: \(error)")
                }
                try? await Task.sleep(for: .milliseconds(150))
                onReady?()
            }
            return
        }

        // No pending device — standard mic initialization.
        //
        // CRITICAL: Stop the engine BEFORE accessing engine.input. Accessing
        // engine.input on a running engine triggers the HAL to activate full-duplex
        // I/O, which can renegotiate the buffer size (e.g. MOTU M2: 480 → 512).
        // If we build the mic graph while running, the render thread may pull
        // through newly attached nodes before syncMaxFramesPerSlice() runs.
        //
        // When called from setInputDevice(), the engine is already stopped
        // (engineIsRunning == false) so the stop() below is a harmless no-op.
        // This avoids the old double stop/start that caused the mic icon to flash.
        if engineIsRunning {
            if wasPlaying { pause() }
            stopEngineForGraphMutation()
        }

        guard let input = engine.input else {
            print("[AudioEngineManager] engine.input is nil; microphone not available yet")
            // Try to restart so playback still works even without mic.
            do {
                try start()
            } catch {
                print("[AudioEngineManager] Engine restart failed: \(error)")
            }
            return
        }
        mic = input
        isMicrophoneAuthorized = true

        // Route mic through mono downmix -> effects chain -> monitor mixer -> main output.
        // The mono mixer forces single-channel input (e.g. MOTU M2 left-only) to be
        // centered in both ears when downstream nodes up-mix back to stereo.
        let mono = createMonoMixer(for: input)
        micMonoMixer = mono
        let fx = EffectsProcessor(input: mono)
        micEffects = fx
        onMicEffectsReady?(fx)
        let monitor = Mixer(fx.output)
        monitor.volume = isMicMonitoring ? 1 : 0
        micMonitorMixer = monitor
        mainMixer.addInput(monitor)
        let inFmt = input.avAudioNode.outputFormat(forBus: 0)
        print(
            "[AudioEngineManager][DEBUG] initializeMicInput standard path " +
            "input sr=\(Int(inFmt.sampleRate)) ch=\(inFmt.channelCount) " +
            "monoOut sr=\(Int(mono.outputFormat.sampleRate)) ch=\(mono.outputFormat.channelCount)"
        )
        fx.debugDumpNodeFormats(context: "standard-path(pre-start)")

        // Sync mMaxFramesPerSlice (fixed 4096 upper bound) on all nodes —
        // including the freshly created EffectsProcessor nodes.
        syncMaxFramesPerSlice()

        beginTransitionMuteIfNeeded()
        do {
            debugLogRenderConfig("initializeMicInput(pre-start)")
            try engine.start()
            engineIsRunning = true
            if let deviceID = getCurrentOutputDeviceID(),
               let frames = AudioDeviceManager.currentBufferFrameSize(for: deviceID) {
                currentBufferSize = frames
            }
            debugLogRenderConfig("initializeMicInput(post-start)")
            updateVisualizerTapState()
            endTransitionMuteIfNeeded()
            if wasPlaying { play() }
        } catch {
            endTransitionMuteIfNeeded()
            print("[AudioEngineManager] Failed to start engine with mic: \(error)")
        }

        // Defer onReady so AVAudioEngine finishes hardware reconfiguration
        // before PitchTap.start() is called.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            onReady?()
        }
    }

    // MARK: - Mono Downmix Helper

    /// Create a Mixer that forces its output to mono so a single-channel mic input
    /// (e.g. left-only from an audio interface) gets centered in both ears.
    /// AVAudioEngine automatically up-mixes mono → stereo at the next stereo node.
    private func createMonoMixer(for input: Node) -> Mixer {
        let mono = Mixer(input)
        // NOTE:
        // Forcing mono here can produce format-negotiation failures on some hardware
        // (seen as kAudioUnitErr_InvalidElement / kAudioUnitErr_FormatNotSupported
        // during graph initialization). Keep this mixer in the engine's native format
        // for stability; we'll add a safer mono-centering strategy separately.
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
