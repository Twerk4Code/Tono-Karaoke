import Foundation
import SwiftUI
import CoreAudio

/// Global app state — single source of truth, injected via @Environment.
@Observable
@MainActor
final class AppState {
    private static let visualizerCrashGuardKey = "com.tono.visualizer.crash_guard_active"
    private static let visualizerStabilityMigrationKey = "com.tono.visualizer_stability_migration_v1"

    // MARK: - Core Services
    let library = SongLibrary()
    let stemStore = StemFileStore.shared
    let uploadStore = UploadFileStore.shared
    let audioEngine = AudioEngineManager()
    let deviceManager = AudioDeviceManager()
    let vocalSeparator = VocalSeparator()
    let pitchTracker = PitchTracker()
    let playbackVisualizer = PlaybackVisualizerAnalyzer(nFFT: 512)
    let micSpectrumAnalyzer = MicSpectrumAnalyzer()
    let settings = AppSettings.load()
    let lyricsService = LyricsService.shared

    // MARK: - Navigation
    var selectedSong: Song?

    // MARK: - Queue (session-only, not persisted)
    var songQueue: [Song] = []
    var userDidStop = false

    // MARK: - Gig Mode
    var isGigModeActive = false

    // MARK: - Import State
    var importProgress: Double = 0
    var isImporting = false
    var importError: String?

    // MARK: - Lyrics Fetching
    private var lyricsFetchTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Import Choice Dialog
    var pendingImportURLs: [URL]?
    var showImportChoiceDialog = false

    // MARK: - Error State
    var currentError: String?

    // MARK: - Init
    init() {
        setPitchConfidenceThreshold(settings.pitchConfidenceThreshold)

        if !Self.isVisualizerStabilityMigrationApplied() {
            Self.setVisualizerStabilityMigrationApplied(true)
            if settings.visualizer.isEnabled {
                settings.visualizer.isEnabled = false
                currentError = "Visualizer was turned off for a stability update. Re-enable it in Settings."
            }
        }

        if settings.visualizer.isEnabled && Self.isVisualizerCrashGuardActive() {
            settings.visualizer.isEnabled = false
            Self.setVisualizerCrashGuardActive(false)
            currentError = "Visualizer was automatically disabled after a previous crash. Re-enable it in Settings."
        }

        // Request mic permission early so the dialog appears before the user needs the mic.
        // This is a non-blocking permission request and does NOT start the mic path.
        audioEngine.requestMicrophonePermission()

        // Queue the saved input device ID so it is applied when setupMicrophone() runs.
        // We write directly to pendingInputDeviceID instead of calling applyInputDevice()
        // (which routes through setInputDevice → avEngine_inputUnitExists → inputNode).
        // Accessing inputNode on a stopped engine forces the HAL to activate input hardware
        // with device ID 0 (kAudioObjectUnknown), producing a cascade of CoreAudio errors
        // before the engine has even started.
        if let uid = settings.selectedInputDeviceID, !uid.isEmpty {
            let id = deviceManager.deviceID(forUID: uid)
            if id != AudioDeviceID(kAudioObjectUnknown) {
                audioEngine.setPendingInputDevice(id)
            }
        }

        // Apply saved buffer size directly to the output hardware BEFORE starting the engine,
        // so that AVAudioEngine's first start sees the correct buffer size and mMaxFramesPerSlice
        // is negotiated correctly from the very first render cycle.
        if let frames = settings.bufferFrameSize,
           let deviceID = audioEngine.getCurrentOutputDeviceID() {
            AudioDeviceManager.setBufferFrameSize(frames, for: deviceID)
        }

        // Single engine start — syncMaxFramesPerSlice() is called inside start().
        do {
            try audioEngine.start()
        } catch {
            currentError = "Audio engine failed to start: \(error.localizedDescription)"
        }

        // Apply saved output device synchronously now that the engine is running.
        // Skip when no explicit override is saved; startup already uses system default.
        if let savedOutputUID = settings.selectedOutputDeviceID, !savedOutputUID.isEmpty {
            // setOutputDevice() does NOT enqueue a Task — it sets the property inline.
            applyOutputDevice(savedOutputUID)
        }

        // Always resolve and queue the input route (saved or system default) up front.
        // This guarantees setupMicrophone() applies a concrete input device instead of
        // relying on whatever AVAudioEngine currently reports as implicit default.
        applyInputDevice(settings.selectedInputDeviceID)

        // Restore persisted playback rate and pitch shift.
        audioEngine.playbackRate = settings.playbackRate
        audioEngine.pitchShiftSemitones = settings.pitchShiftSemitones

        audioEngine.configureVisualizerAnalyzer(playbackVisualizer)
        playbackVisualizer.setIntensity(Float(settings.visualizer.intensity))
        playbackVisualizer.setEnabled(settings.visualizer.isEnabled)
        if settings.visualizer.isEnabled {
            armVisualizerCrashGuardWindow()
        }
        audioEngine.refreshVisualizerTapState()

        audioEngine.installMicSpectrumTap { [weak micSpectrumAnalyzer] buffer, _ in
            micSpectrumAnalyzer?.processSampleBuffer(buffer)
        }

        // Re-attach PitchTracker and restore device selection after the engine
        // recovers from a hardware change (e.g. device plug/unplug, sample-rate change).
        // The mic path is rebuilt by handleConfigurationChange() before this callback fires.
        audioEngine.onEngineRestarted = { [weak self] in
            guard let self else { return }
            // Re-apply saved device selections so the MOTU M2 (or any non-default
            // device) is restored after a configuration-change restart.
            if let savedOutputUID = self.settings.selectedOutputDeviceID, !savedOutputUID.isEmpty {
                self.applyOutputDevice(savedOutputUID)
            }
            self.applyInputDevice(self.settings.selectedInputDeviceID)
            self.audioEngine.refreshVisualizerTapState()
            // Re-attach pitch tracking if it was active.
            guard self.pitchTracker.isTracking else { return }
            self.pitchTracker.stopTracking()
            guard let trackingNode = self.audioEngine.pitchTrackingNode else { return }
            let started = self.pitchTracker.start(inputNode: trackingNode)
            if !started {
                print("[AppState] onEngineRestarted: pitchTracker.start() returned false")
            }
        }

        audioEngine.onPlaybackFinished = { [weak self] in
            self?.handlePlaybackFinished()
        }

        // Re-apply the saved output device after setInputDevice rebuilds the mic path.
        // Uses a dedicated callback to avoid the onEngineRestarted → setInputDevice loop.
        audioEngine.onInputDeviceApplied = { [weak self] in
            guard let self else { return }
            if let savedOutputUID = self.settings.selectedOutputDeviceID, !savedOutputUID.isEmpty {
                self.applyOutputDevice(savedOutputUID)
            }
        }
    }

    // MARK: - Device Selection

    /// Apply an output device UID string (from Settings) to the audio engine.
    /// Passing nil or an unresolvable UID reverts to the system default.
    func applyOutputDevice(_ uid: String?) {
        let deviceID: AudioDeviceID
        if let uid, !uid.isEmpty {
            deviceID = deviceManager.deviceID(forUID: uid)
        } else {
            deviceID = AudioDeviceID(kAudioObjectUnknown)
        }
        audioEngine.setOutputDevice(deviceID)
    }

    /// Apply an input device UID string (from Settings) to the audio engine.
    /// Safe to call at any time — if the mic path is not yet live the device ID
    /// is queued inside AudioEngineManager and applied once setupMicrophone runs.
    func applyInputDevice(_ uid: String?) {
        let deviceID: AudioDeviceID
        if let uid, !uid.isEmpty {
            deviceID = deviceManager.deviceID(forUID: uid)
        } else {
            deviceID = AudioDeviceID(kAudioObjectUnknown)
        }
        audioEngine.setInputDevice(deviceID)
    }

    // MARK: - Pitch Tracking

    func setPitchConfidenceThreshold(_ value: Float) {
        let clamped = max(0.01, min(0.2, value))
        settings.pitchConfidenceThreshold = clamped
        pitchTracker.setConfidenceThreshold(clamped)
    }

    // MARK: - Visualizer

    func setVisualizerEnabled(_ enabled: Bool) {
        if enabled {
            armVisualizerCrashGuardWindow()
        } else {
            Self.setVisualizerCrashGuardActive(false)
        }
        settings.visualizer.isEnabled = enabled
        playbackVisualizer.setEnabled(enabled)
        audioEngine.refreshVisualizerTapState()
    }

    func setVisualizerIntensity(_ value: Double) {
        let clamped = max(0.15, min(0.8, value))
        settings.visualizer.intensity = clamped
        playbackVisualizer.setIntensity(Float(clamped))
    }

    func setVisualizerPlacement(_ placement: VisualizerSettings.Placement) {
        settings.visualizer.placement = placement
    }

    func setVisualizerStyle(_ style: VisualizerSettings.Style) {
        settings.visualizer.style = style
    }

    func setVisualizerReadabilityScrim(_ value: Double) {
        let clamped = max(0.20, min(0.85, value))
        settings.visualizer.readabilityScrim = clamped
    }

    /// Lyrics-pane quick toggle: enables/disables the Apple movie mode directly in the panel UI.
    func setLyricsMovieModeEnabled(_ enabled: Bool) {
        if enabled {
            settings.visualizer.placement = .lyricsPane
            settings.visualizer.style = .appleMovie
            setVisualizerEnabled(true)
        } else {
            setVisualizerEnabled(false)
        }
    }

    private func armVisualizerCrashGuardWindow() {
        Self.setVisualizerCrashGuardActive(true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            Self.setVisualizerCrashGuardActive(false)
        }
    }

    private static func isVisualizerCrashGuardActive() -> Bool {
        UserDefaults.standard.bool(forKey: visualizerCrashGuardKey)
    }

    private static func setVisualizerCrashGuardActive(_ active: Bool) {
        UserDefaults.standard.set(active, forKey: visualizerCrashGuardKey)
    }

    private static func isVisualizerStabilityMigrationApplied() -> Bool {
        UserDefaults.standard.bool(forKey: visualizerStabilityMigrationKey)
    }

    private static func setVisualizerStabilityMigrationApplied(_ applied: Bool) {
        UserDefaults.standard.set(applied, forKey: visualizerStabilityMigrationKey)
    }

    // MARK: - Error Management

    func dismissError() {
        currentError = nil
    }

    func dismissImportError() {
        importError = nil
    }

    // MARK: - Import Flow

    /// Validate file(s) and show the import mode choice dialog.
    func beginImport(from urls: [URL]) {
        let audioExtensions: Set<String> = ["mp3", "wav", "m4a"]
        let valid = urls.filter { audioExtensions.contains($0.pathExtension.lowercased()) }
        guard !valid.isEmpty else { return }
        pendingImportURLs = valid
        showImportChoiceDialog = true
    }

    /// Called when user picks "Separate Stems" in the choice dialog.
    func importWithStemSeparation() {
        guard let urls = pendingImportURLs else { return }
        pendingImportURLs = nil
        showImportChoiceDialog = false
        Task {
            for url in urls {
                await importSong(from: url, mode: .separated)
            }
        }
    }

    /// Called when user picks "Raw Upload" in the choice dialog.
    func importRaw() {
        guard let urls = pendingImportURLs else { return }
        pendingImportURLs = nil
        showImportChoiceDialog = false
        Task {
            for url in urls {
                await importSong(from: url, mode: .raw)
            }
        }
    }

    /// Import a song file with the given mode. For `.raw`, skips RoFormer entirely.
    func importSong(from url: URL, mode: ImportMode = .separated) async {
        // Verify file exists and is readable
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            importError = "Cannot read file: \(url.lastPathComponent)"
            return
        }

        let filename = url.deletingPathExtension().lastPathComponent
        let songID = UUID()

        // Extract ID3 metadata (title, artist, album art)
        let meta = await MetadataExtractor.extract(from: url)
        var song = Song(
            id: songID,
            title: meta.title ?? filename,
            artist: meta.artist ?? "Unknown Artist",
            originalURL: url,
            albumArt: meta.albumArt,
            duration: meta.duration,
            importMode: mode
        )

        do {
            song.storedUploadURL = try uploadStore.storeUpload(from: url, songID: songID)
        } catch {
            importError = "Could not copy upload to app storage: \(url.lastPathComponent)"
        }

        // Trigger background lyrics fetch (non-blocking)
        beginLyricsFetch(for: song)

        // Raw upload — add directly with no stem processing
        if mode == .raw {
            library.addSong(song)
            selectSong(song)
            return
        }

        // Re-import optimization: if this source file was already separated before,
        // copy cached stems into this song's own stem filenames and skip ML inference.
        if let reusable = existingSeparatedStems(for: url) {
            do {
                let copied = try copyStems(
                    vocalURL: reusable.vocalURL,
                    instrumentalURL: reusable.instrumentalURL,
                    toSongID: songID
                )
                song.vocalURL = copied.vocalURL
                song.instrumentalURL = copied.instrumentalURL
                library.addSong(song)
                selectSong(song)
                return
            } catch {
                // Fall through to full separation if copying cached stems fails.
                print("[AppState] Reuse stems copy failed, falling back to separation: \(error)")
            }
        }

        isImporting = true
        importProgress = 0
        importError = nil

        let (stream, vocalURL, instrumentalURL) = vocalSeparator.separate(
            inputURL: url,
            outputDirectory: stemStore.stemsDirectory,
            songID: songID
        )

        do {
            for try await progress in stream {
                importProgress = progress
            }
            song.vocalURL = vocalURL
            song.instrumentalURL = instrumentalURL
            library.addSong(song)
            selectSong(song)
        } catch {
            importError = "Stem separation failed: \(error.localizedDescription)"
        }

        isImporting = false
    }

    private func existingSeparatedStems(for originalURL: URL) -> (vocalURL: URL, instrumentalURL: URL)? {
        let normalized = originalURL.standardizedFileURL.resolvingSymlinksInPath()
        for song in library.songs where song.importMode == .separated {
            guard song.originalURL.standardizedFileURL.resolvingSymlinksInPath() == normalized,
                  let vocalURL = song.vocalURL,
                  let instrumentalURL = song.instrumentalURL,
                  FileManager.default.fileExists(atPath: vocalURL.path),
                  FileManager.default.fileExists(atPath: instrumentalURL.path) else {
                continue
            }
            return (vocalURL, instrumentalURL)
        }
        return nil
    }

    private func copyStems(
        vocalURL: URL,
        instrumentalURL: URL,
        toSongID songID: UUID
    ) throws -> (vocalURL: URL, instrumentalURL: URL) {
        let newVocalURL = stemStore.vocalURL(for: songID)
        let newInstrumentalURL = stemStore.instrumentalURL(for: songID)
        let fm = FileManager.default

        try fm.createDirectory(at: stemStore.stemsDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: newVocalURL.path) {
            try? fm.removeItem(at: newVocalURL)
        }
        if fm.fileExists(atPath: newInstrumentalURL.path) {
            try? fm.removeItem(at: newInstrumentalURL)
        }

        try fm.copyItem(at: vocalURL, to: newVocalURL)
        do {
            try fm.copyItem(at: instrumentalURL, to: newInstrumentalURL)
        } catch {
            try? fm.removeItem(at: newVocalURL)
            throw error
        }

        return (newVocalURL, newInstrumentalURL)
    }

    // MARK: - Song Selection

    func selectSong(_ song: Song) {
        userDidStop = false
        // Stop pitch tracking before switching songs — prevents CoreAudio deadlock
        let wasTracking = pitchTracker.isTracking
        if wasTracking {
            pitchTracker.stopTracking()
        }
        audioEngine.stopAndWait()
        selectedSong = song
        audioEngine.pitchShiftSemitones = 0
        settings.pitchShiftSemitones = 0

        if song.importMode == .raw {
            // Raw mode: load original file directly, no stems needed
            let playbackCandidates = [song.playbackURL, song.originalURL]
            let rawURL = playbackCandidates.first { FileManager.default.fileExists(atPath: $0.path) }

            guard let rawURL else {
                currentError = "Audio file missing from disk. Please re-import this song."
                library.deleteSong(song)
                selectedSong = nil
                return
            }
            do {
                try audioEngine.loadRawSong(url: rawURL)
            } catch {
                currentError = "Failed to load audio: \(error.localizedDescription)"
            }
        } else {
            guard let vocalURL = song.vocalURL, let instrumentalURL = song.instrumentalURL else {
                currentError = "Song stems not found. Try re-importing."
                return
            }

            // Verify stem files still exist on disk
            guard FileManager.default.fileExists(atPath: vocalURL.path),
                  FileManager.default.fileExists(atPath: instrumentalURL.path) else {
                currentError = "Stem files missing from disk. Please re-import this song."
                library.deleteSong(song)
                selectedSong = nil
                return
            }

            do {
                try audioEngine.loadStems(vocalURL: vocalURL, instrumentalURL: instrumentalURL)
            } catch {
                currentError = "Failed to load audio: \(error.localizedDescription)"
            }
        }

        // Restart engine if it stopped unexpectedly
        if !audioEngine.engineIsRunning {
            do {
                try audioEngine.start()
            } catch {
                currentError = "Audio engine restart failed: \(error.localizedDescription)"
            }
        }

        // Re-attach pitch tracker if it was running before the song switch
        if wasTracking, let trackingNode = audioEngine.pitchTrackingNode {
            let started = pitchTracker.start(inputNode: trackingNode)
            if !started {
                print("[AppState] selectSong: pitchTracker.start() returned false after song switch")
            }
        }
    }

    // MARK: - Queue Management

    func addToQueue(_ song: Song) {
        songQueue.append(song)
    }

    func removeFromQueue(at offsets: IndexSet) {
        songQueue.remove(atOffsets: offsets)
    }

    func moveQueueItems(from source: IndexSet, to destination: Int) {
        songQueue.move(fromOffsets: source, toOffset: destination)
    }

    func clearQueue() {
        songQueue.removeAll()
    }

    func enterGigMode() {
        guard !songQueue.isEmpty || selectedSong != nil else { return }
        isGigModeActive = true
    }

    func exitGigMode() {
        isGigModeActive = false
    }

    func advanceQueue() {
        guard !songQueue.isEmpty else { return }
        let next = songQueue.removeFirst()
        selectSong(next)
    }

    private func handlePlaybackFinished() {
        guard !userDidStop, !songQueue.isEmpty else { return }
        advanceQueue()
    }

    // MARK: - Lyrics Fetching

    /// Begin fetching and caching lyrics for a song (non-blocking, background task)
    private func beginLyricsFetch(for song: Song) {
        let task = Task {
            await fetchAndCacheLyrics(for: song)
        }
        lyricsFetchTasks[song.id] = task
    }

    /// Fetch lyrics from LRCLIB and update the song with the lrcURL
    private func fetchAndCacheLyrics(for song: Song) async {
        let stream = lyricsService.fetchAndCache(
            title: song.title,
            artist: song.artist,
            songID: song.id
        )

        do {
            for try await _ in stream {
                // Progress stream yields 0.0, 0.5, 0.9, 1.0
                // We don't display progress for lyrics (optional feature)
            }
            // If successful, update song with lrcURL
            guard var updated = library.song(for: song.id) else {
                lyricsFetchTasks.removeValue(forKey: song.id)
                return
            }
            updated.lrcURL = LyricsCache.shared.lyricsURL(for: song.id)
            library.updateSong(updated)
            // Keep selectedSong in sync so LyricsDisplay sees the new lrcURL
            if selectedSong?.id == updated.id {
                selectedSong = updated
            }
        } catch {
            // Gracefully ignore lyrics fetch errors — feature is optional
            // Song can still be played without lyrics
        }

        // Clean up the task reference
        lyricsFetchTasks.removeValue(forKey: song.id)
    }

    /// Clears the lrcURL from a song (called when the user wants to re-assign lyrics).
    func clearLyrics(for songID: UUID) {
        if var song = library.song(for: songID) {
            song.lrcURL = nil
            library.updateSong(song)
        }
        if selectedSong?.id == songID {
            selectedSong?.lrcURL = nil
        }
    }

    /// Called after the user manually selects lyrics from the search UI.
    /// Updates the song's lrcURL in the library and keeps selectedSong in sync.
    func assignLyrics(to songID: UUID) {
        guard LyricsCache.shared.hasLyrics(for: songID) else { return }
        let lrcURL = LyricsCache.shared.lyricsURL(for: songID)
        if var song = library.song(for: songID) {
            song.lrcURL = lrcURL
            library.updateSong(song)
        }
        if selectedSong?.id == songID {
            selectedSong?.lrcURL = lrcURL
        }
    }

    // MARK: - Metadata Editing

    func updateSongMetadata(id: UUID, title: String, artist: String) {
        guard var song = library.song(for: id) else { return }
        song.title = title
        song.artist = artist
        library.updateSong(song)
        if selectedSong?.id == id {
            selectedSong = song
        }
    }

    /// Delete lyrics when a song is deleted
    func deleteLyricsForSong(_ songID: UUID) {
        lyricsFetchTasks[songID]?.cancel()
        lyricsFetchTasks.removeValue(forKey: songID)
        LyricsCache.shared.deleteLyrics(for: songID)
    }
}
