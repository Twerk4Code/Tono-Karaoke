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
    private var playbackTimer: Timer?

    // When the user seeks, the engine seek is dispatched asynchronously.
    // We hold the target time here and ignore engine-reported currentTime
    // until the engine catches up, preventing the cursor from slingshoting back.
    private var pendingSeekTime: TimeInterval? = nil
    private static let seekSettleThreshold: TimeInterval = 0.15

    init(appState: AppState) {
        self.appState = appState
        startTimer()
    }

    deinit {
        // PlayerViewModel is always created/destroyed on the main thread via @State,
        // so assumeIsolated is safe for timer cleanup.
        MainActor.assumeIsolated {
            playbackTimer?.invalidate()
            waveformTask?.cancel()
        }
    }

    // Poll the audio engine at ~30 fps so the waveform cursor and time labels
    // update smoothly without relying on any other observable side-effects.
    private func startTimer() {
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.tick()
            }
        }
        playbackTimer?.tolerance = 0.005
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
    func stop() { appState.audioEngine.stop() }

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
