import SwiftUI
import AppKit
import AVFoundation

struct PerformanceView: View {
    @Environment(AppState.self) private var appState
    @EnvironmentObject private var audioEngine: AudioEngineManager
    @State private var playerVM: PlayerViewModel?
    @State private var pitchVM: PitchViewModel?
    @State private var effectsVM: EffectsViewModel?
    @State private var showEffects = false
    @State private var showHeadphoneWarning = false
    @State private var isLyricsSearchFocused = false
    @State private var showQueue = false
    @State private var showEditMetadata = false

    var body: some View {
        ZStack {
            TonoColors.background
                .ignoresSafeArea()

            if appState.settings.visualizer.isEnabled &&
                appState.settings.visualizer.placement == .globalBackground {
                ReactiveVisualizerBackgroundView(
                    analyzer: appState.playbackVisualizer,
                    intensity: appState.settings.visualizer.intensity
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .blendMode(.plusLighter)
                .opacity(0.78)
                .zIndex(0)
                .transition(.opacity)
            }

            if let player = playerVM, let pitch = pitchVM, let effects = effectsVM {
                content(player: player, pitch: pitch, effects: effects)
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if playerVM == nil  { playerVM  = PlayerViewModel(appState: appState) }
            if pitchVM == nil   { pitchVM   = PitchViewModel(appState: appState) }
            if effectsVM == nil { effectsVM = EffectsViewModel(appState: appState) }
            if let song = appState.selectedSong { playerVM?.loadWaveform(for: song) }
        }
        .onChange(of: appState.selectedSong) { _, newSong in
            if let song = newSong { playerVM?.loadWaveform(for: song) }
        }
        .onDisappear {
            // CRITICAL: stop pitch tap before view disappears — prevents CoreAudio deadlock
            pitchVM?.disable()
        }
        .onKeyPress(.space) {
            guard !isLyricsSearchFocused else { return .ignored }
            playerVM?.togglePlayPause()
            return .handled
        }
        .onKeyPress(.escape) {
            guard !isLyricsSearchFocused else { return .ignored }
            playerVM?.stop()
            return .handled
        }
        .animation(.easeInOut(duration: 0.2), value: appState.settings.visualizer.isEnabled)
    }

    @ViewBuilder
    private func content(player: PlayerViewModel, pitch: PitchViewModel, effects: EffectsViewModel) -> some View {
        HStack(spacing: 0) {
            // Left: Main performance content
            ScrollView {
                VStack(spacing: 0) {
                // Top bar — song info with album art
                if let song = appState.selectedSong {
                    HStack(spacing: 16) {
                        // Album art
                        ZStack {
                            RoundedRectangle(cornerRadius: TonoRadius.medium, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                                .frame(width: 56, height: 56)

                            if let artData = song.albumArt, let nsImage = NSImage(data: artData) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: TonoRadius.medium, style: .continuous))
                            } else {
                                Image(systemName: "music.note")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(TonoColors.cyan.opacity(0.6))
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(song.title)
                                .font(.system(.title3, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                            Text(song.artist)
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(TonoColors.textSecondary)
                        }

                        Button {
                            showEditMetadata = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(TonoColors.textTertiary)
                                .padding(6)
                                .background(Color.white.opacity(0.06), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Edit song info")
                        .sheet(isPresented: $showEditMetadata) {
                            EditSongMetadataSheet(song: song) { newTitle, newArtist in
                                appState.updateSongMetadata(id: song.id, title: newTitle, artist: newArtist)
                            }
                        }

                        Spacer()

                        // Gig Mode button — visible when a song is loaded
                        Button {
                            appState.enterGigMode()
                        } label: {
                            Image(systemName: "theatermasks.fill")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(TonoColors.cyan)
                        }
                        .buttonStyle(.plain)
                        .help("Gig Mode")
                        .opacity(appState.selectedSong != nil ? 1 : 0)
                        .allowsHitTesting(appState.selectedSong != nil)

                        // Queue button
                        Button {
                            showQueue = true
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(appState.songQueue.isEmpty ? TonoColors.textSecondary : TonoColors.cyan)
                                if !appState.songQueue.isEmpty {
                                    Text("\(appState.songQueue.count)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 3)
                                        .padding(.vertical, 1)
                                        .background(TonoColors.cyan, in: Capsule())
                                        .offset(x: 8, y: -6)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Queue")
                        .sheet(isPresented: $showQueue) {
                            QueueView()
                                .environment(appState)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.top, 28)
                    .padding(.bottom, 20)
                }

                // Pitch display (center stage)
                PitchDisplay(reading: pitch.currentReading, isActive: pitch.isEnabled)
                    .padding(.top, 24)
                    .padding(.bottom, 32)

                // Waveform / progress
                Group {
                    if let samples = player.waveformSamples {
                        WaveformView(
                            samples: samples,
                            progress: player.progress,
                            currentTime: player.currentTime,
                            duration: player.duration,
                            onSeek: { player.seek(to: $0) }
                        )
                    } else if player.isLoadingWaveform {
                        WaveformPlaceholder()
                    } else {
                        ProgressBar(
                            progress: player.progress,
                            currentTime: player.currentTime,
                            duration: player.duration
                        ) { newProgress in
                            player.seek(to: newProgress)
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 28)

                // Transport controls
                TransportControls(
                    isPlaying: player.isPlaying,
                    isPitchEnabled: pitch.isEnabled,
                    isMicMonitoring: audioEngine.isMicMonitoring,
                    onPlayPause: { player.togglePlayPause() },
                    onStop: { player.stop() },
                    onPitchToggle: { pitch.toggle() },
                    onMicMonitorToggle: {
                        if audioEngine.isMicMonitoring {
                            // Turn off — no warning needed
                            audioEngine.isMicMonitoring = false
                        } else {
                            // Show headphone warning before enabling
                            showHeadphoneWarning = true
                        }
                    }
                )
                .padding(.bottom, 8)

                // Up Next label
                if let nextSong = appState.songQueue.first {
                    HStack(spacing: 6) {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TonoColors.cyan.opacity(0.7))
                        Text("Up Next:")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(TonoColors.textSecondary)
                        Text(nextSong.title)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(TonoColors.textSecondary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Playback speed control
                PlaybackSpeedControl(
                    playbackRate: Binding(
                        get: { player.playbackRate },
                        set: { player.playbackRate = $0 }
                    )
                )
                .padding(.bottom, 8)

                // Key transposition control
                KeyTransposeControl(
                    semitones: Binding(
                        get: { player.pitchShiftSemitones },
                        set: { player.pitchShiftSemitones = $0 }
                    )
                )
                .padding(.bottom, 24)
                .alert("Use Headphones", isPresented: $showHeadphoneWarning) {
                    Button("Enable Monitoring") {
                        audioEngine.setupMicrophone {
                            guard audioEngine.mic != nil else {
                                let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                                if permissionStatus == .denied || permissionStatus == .restricted {
                                    appState.currentError = "Microphone access is disabled for Tono. Enable it in System Settings > Privacy & Security > Microphone."
                                } else {
                                    appState.currentError = "Microphone not available. Select an input device in Settings."
                                }
                                audioEngine.isMicMonitoring = false
                                return
                            }
                            audioEngine.isMicMonitoring = true
                        }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Monitoring plays your mic through the speakers with FX applied. Use headphones to avoid feedback.")
                }

                // Mixer
                MixerPanel(
                    vocalVolume: Binding(
                        get: { player.vocalVolume },
                        set: { player.vocalVolume = $0 }
                    ),
                    instrumentalVolume: Binding(
                        get: { player.instrumentalVolume },
                        set: { player.instrumentalVolume = $0 }
                    ),
                    micBusLeftGain: Binding(
                        get: { audioEngine.micBusLeftGain },
                        set: { audioEngine.micBusLeftGain = $0 }
                    ),
                    micBusRightGain: Binding(
                        get: { audioEngine.micBusRightGain },
                        set: { audioEngine.micBusRightGain = $0 }
                    ),
                    showEffects: $showEffects,
                    effectsActive: effects.isAnyEffectActive,
                    isRawMode: appState.audioEngine.isRawMode,
                    isMicMonitoring: audioEngine.isMicMonitoring
                )
                .padding(.horizontal, 32)
                .padding(.bottom, 12)

                // Effects panel — slides in below mixer when FX is toggled
                if showEffects {
                    EffectsPanel(vm: effects, micSpectrumAnalyzer: appState.micSpectrumAnalyzer)
                        .padding(.horizontal, 32)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                Spacer(minLength: 32)
                }
                .animation(.spring(duration: 0.35, bounce: 0.15), value: showEffects)
            }
            .scrollIndicators(.hidden)
            .focusable()
            .focusEffectDisabled()

            // Right: Lyrics sidebar
            if let song = appState.selectedSong {
                Divider()

                LyricsDisplay(
                    songID: song.id,
                    lrcURL: song.lrcURL,
                    currentTime: playerVM?.currentTime ?? 0,
                    isPlaying: playerVM?.isPlaying ?? false,
                    songTitle: song.title,
                    songArtist: song.artist,
                    isSearchFieldFocused: $isLyricsSearchFocused
                )
                .frame(width: 300)
            }
        }
    }
}

private struct ProgressBar: View {
    let progress: Double
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 4)
                    Capsule()
                        .fill(TonoColors.cyan)
                        .frame(width: geo.size.width * max(0, min(1, progress)), height: 4)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let p = max(0, min(1, value.location.x / geo.size.width))
                            onSeek(p)
                        }
                )
            }
            .frame(height: 4)

            HStack {
                Text(currentTime.mmss)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(TonoColors.textTertiary)
                Spacer()
                Text(duration.mmss)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(TonoColors.textTertiary)
            }
        }
    }
}
