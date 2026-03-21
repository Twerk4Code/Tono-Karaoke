import Foundation
import SwiftUI

@Observable
@MainActor
final class PlayerViewModel {

    private let appState: AppState

    var vocalVolume: Double {
        get { appState.audioEngine.vocalVolume }
        set { appState.audioEngine.vocalVolume = newValue }
    }

    var instrumentalVolume: Double {
        get { appState.audioEngine.instrumentalVolume }
        set { appState.audioEngine.instrumentalVolume = newValue }
    }

    var playbackRate: Double {
        get { appState.audioEngine.playbackRate }
        set {
            appState.audioEngine.playbackRate = newValue
            appState.settings.playbackRate = newValue
        }
    }

    var pitchShiftSemitones: Int {
        get { appState.audioEngine.pitchShiftSemitones }
        set {
            appState.audioEngine.pitchShiftSemitones = newValue
            appState.settings.pitchShiftSemitones = newValue
        }
    }

    // Stored properties so @Observable tracks changes and drives UI updates.
    // A timer polls the audio engine and writes here at ~30 fps while playing.
    private(set) var isPlaying: Bool = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    // MARK: - Waveform
    var waveformSamples: [Float]?
    var isLoadingWaveform = false
    private var waveformTask: Task<Void, Never>?
    private var waveformSongID: UUID?

    // MARK: - Playback Timer
    private var playbackLoopTask: Task<Void, Never>?
    private static let activeTickInterval: Duration = .milliseconds(33)
    private static let idleTickInterval: Duration = .milliseconds(120)

    // When the user seeks, the engine seek is dispatched asynchronously.
    // We hold the target time here and ignore engine-reported currentTime
    // until the engine catches up, preventing the cursor from slingshoting back.
    private var pendingSeekTime: TimeInterval? = nil
    private static let seekSettleThreshold: TimeInterval = 0.15

    init(appState: AppState) {
        self.appState = appState
        startPlaybackLoop()
    }

    deinit {
        MainActor.assumeIsolated {
            playbackLoopTask?.cancel()
            waveformTask?.cancel()
        }
    }

    // Keep a single polling task alive instead of spawning one Task per timer fire.
    private func startPlaybackLoop() {
        playbackLoopTask?.cancel()
        playbackLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                let interval = self.isPlaying ? Self.activeTickInterval : Self.idleTickInterval
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func tick() async {
        let snapshot = await appState.audioEngine.playbackSnapshot()
        isPlaying = snapshot.isPlaying
        duration = snapshot.duration

        let engineTime = snapshot.currentTime

        // If we have a pending seek, keep displaying the target time until the
        // engine actually arrives within a small threshold of it.
        if let target = pendingSeekTime {
            if abs(engineTime - target) < Self.seekSettleThreshold {
                pendingSeekTime = nil
                currentTime = engineTime
            } else {
                currentTime = target
            }
        } else {
            currentTime = engineTime
        }
    }

    // MARK: - Transport

    func play() { appState.audioEngine.play() }
    func pause() { appState.audioEngine.pause() }
    func stop() {
        appState.userDidStop = true
        appState.audioEngine.stop()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to progress: Double) {
        let time = progress * duration
        appState.audioEngine.seek(to: time)
        // Optimistically move the cursor; pendingSeekTime prevents tick() from
        // overwriting this until the async engine seek settles.
        currentTime = time
        pendingSeekTime = time
    }

    // MARK: - Waveform Generation

    func loadWaveform(for song: Song) {
        // Raw songs have no stems — use the original file for waveform generation
        let url: URL
        if song.importMode == .raw {
            let stored = song.playbackURL
            if FileManager.default.fileExists(atPath: stored.path) {
                url = stored
            } else {
                url = song.originalURL
            }
        } else {
            guard let stemURL = song.instrumentalURL ?? song.vocalURL else {
                waveformTask?.cancel()
                waveformSongID = song.id
                waveformSamples = nil
                isLoadingWaveform = false
                return
            }
            url = stemURL
        }
        waveformTask?.cancel()
        waveformSongID = song.id
        isLoadingWaveform = true
        waveformSamples = nil

        let requestSongID = song.id
        waveformTask = Task {
            let samples = try? await WaveformGenerator.generate(from: url, targetSamples: 300)
            guard !Task.isCancelled else { return }
            guard self.waveformSongID == requestSongID else { return }
            self.waveformSamples = samples
            self.isLoadingWaveform = false
        }
    }
}
