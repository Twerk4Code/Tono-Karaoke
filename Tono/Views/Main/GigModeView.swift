import SwiftUI
import AppKit

/// Full-screen, stage-optimized performance view for live gig use.
/// Covers the entire window with large lyrics, minimal chrome, and easy song navigation.
struct GigModeView: View {
    @Environment(AppState.self) private var appState
    @State private var playerVM: PlayerViewModel?
    @State private var lyricsVM = LyricsViewModel()

    // MARK: - Chrome Visibility

    @State private var chromeVisible = true
    @State private var chromeHideTask: Task<Void, Never>?
    @State private var eventMonitor: Any?

    // MARK: - Mixer

    @State private var showMixer = false

    // MARK: - Setlist Complete

    @State private var showSetlistComplete = false

    // MARK: - Double-tap previous tracking

    @State private var lastLeftArrowTime: Date?

    var body: some View {
        ZStack {
            // Pure black background
            Color.black
                .ignoresSafeArea()

            // Optional low-intensity visualizer ambiance
            if appState.settings.visualizer.isEnabled {
                ReactiveVisualizerBackgroundView(
                    analyzer: appState.playbackVisualizer,
                    intensity: appState.settings.visualizer.intensity * 0.4
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .blendMode(.plusLighter)
                .opacity(0.3)
            }

            if let player = playerVM {
                mainContent(player: player)
            }

            // Setlist Complete overlay
            if showSetlistComplete {
                setlistCompleteOverlay
                    .transition(.opacity)
            }

            // Floating mixer
            if showMixer {
                Color.black.opacity(0.01)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.2)) { showMixer = false }
                    }

                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        GigModeFloatingMixer(
                            vocalVolume: Binding(
                                get: { player?.vocalVolume ?? 1.0 },
                                set: { playerVM?.vocalVolume = $0 }
                            ),
                            instrumentalVolume: Binding(
                                get: { player?.instrumentalVolume ?? 1.0 },
                                set: { playerVM?.instrumentalVolume = $0 }
                            ),
                            pitchShiftSemitones: Binding(
                                get: { player?.pitchShiftSemitones ?? 0 },
                                set: { playerVM?.pitchShiftSemitones = $0 }
                            ),
                            playbackRate: Binding(
                                get: { player?.playbackRate ?? 1.0 },
                                set: { playerVM?.playbackRate = $0 }
                            ),
                            isRawMode: appState.audioEngine.isRawMode,
                            onDismiss: {
                                withAnimation(.easeOut(duration: 0.2)) { showMixer = false }
                            }
                        )
                        .padding(.trailing, 32)
                        .padding(.bottom, 200)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
            }
        }
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if playerVM == nil {
                playerVM = PlayerViewModel(appState: appState)
            }
            loadLyricsForCurrentSong()
            // Defer event monitor past the initial NavigationSplitView layout pass
            // to avoid -layoutSubtreeIfNeeded recursion warnings.
            try? await Task.sleep(for: .milliseconds(100))
            installEventMonitor()
            resetChromeTimer()
        }
        .onChange(of: appState.selectedSong?.id) { _, _ in
            loadLyricsForCurrentSong()
        }
        .onDisappear {
            removeEventMonitor()
            chromeHideTask?.cancel()
        }
        .animation(.easeInOut(duration: 0.25), value: chromeVisible)
        .animation(.easeInOut(duration: 0.3), value: showMixer)
        .animation(.easeInOut(duration: 0.5), value: showSetlistComplete)
    }

    // MARK: - Main Content

    @ViewBuilder
    private func mainContent(player: PlayerViewModel) -> some View {
        VStack(spacing: 0) {
            // Top strip — auto-hides
            if chromeVisible {
                topStrip(player: player)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Lyrics area — fills remaining space
            GigModeLyricsView(
                lyrics: lyricsVM.lyrics,
                currentIndex: lyricsVM.currentIndex,
                onTap: { player.togglePlayPause() }
            )
            .onChange(of: player.currentTime) { _, time in
                if player.isPlaying {
                    lyricsVM.update(currentTime: time)
                }
            }

            // Bottom bar — auto-hides
            if chromeVisible {
                bottomBar(player: player)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    // MARK: - Top Strip

    @ViewBuilder
    private func topStrip(player: PlayerViewModel) -> some View {
        HStack(spacing: 16) {
            // Queue position
            if !appState.songQueue.isEmpty {
                let totalSongs = appState.songQueue.count + 1
                Text("1 of \(totalSongs)")
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.4))
            }

            Text("\u{00B7}")
                .foregroundStyle(Color.white.opacity(0.2))

            // Song title
            if let song = appState.selectedSong {
                Text(song.title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer()

            // Key indicator
            if player.pitchShiftSemitones != 0 {
                keyBadge(semitones: player.pitchShiftSemitones)
            }

            // Speed indicator
            if player.playbackRate != 1.0 {
                speedBadge(rate: player.playbackRate)
            }

            // Exit button — right side, clear of window traffic lights
            Button {
                appState.exitGigMode()
            } label: {
                HStack(spacing: 6) {
                    Text("Exit")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.white.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.8), Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        )
    }

    private func keyBadge(semitones: Int) -> some View {
        Text(semitones > 0 ? "Key +\(semitones)" : "Key \(semitones)")
            .font(.system(.caption2, design: .monospaced, weight: .semibold))
            .foregroundStyle(TonoColors.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(TonoColors.cyan.opacity(0.15), in: Capsule())
    }

    private func speedBadge(rate: Double) -> some View {
        Text(String(format: "%.1fx", rate))
            .font(.system(.caption2, design: .monospaced, weight: .semibold))
            .foregroundStyle(TonoColors.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(TonoColors.green.opacity(0.15), in: Capsule())
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private func bottomBar(player: PlayerViewModel) -> some View {
        VStack(spacing: 0) {
            // Song info bar
            HStack(spacing: 16) {
                // Album art
                if let song = appState.selectedSong {
                    ZStack {
                        RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(width: 64, height: 64)
                        if let artData = song.albumArt, let nsImage = NSImage(data: artData) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous))
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 24, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.3))
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(song.artist)
                            .font(.system(size: 18, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Gear (mixer) button
                Button {
                    withAnimation(.spring(duration: 0.25)) { showMixer.toggle() }
                    resetChromeTimer()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(showMixer ? TonoColors.cyan : Color.white.opacity(0.5))
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(showMixer ? 0.12 : 0.06), in: Circle())
                }
                .buttonStyle(.plain)

                // Next button
                Button(action: handleNext) {
                    HStack(spacing: 6) {
                        Text("Next")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)
                .opacity(appState.songQueue.isEmpty ? 0.3 : 1.0)
                .disabled(appState.songQueue.isEmpty)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 12)

            // Transport controls
            GigModeTransportBar(
                isPlaying: player.isPlaying,
                currentTime: player.currentTime,
                duration: player.duration,
                progress: player.progress,
                onPrevious: handlePrevious,
                onStop: {
                    player.stop()
                    appState.exitGigMode()
                },
                onPlayPause: { player.togglePlayPause() },
                onNext: handleNext,
                onSeek: { player.seek(to: $0) }
            )
        }
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Setlist Complete

    private var setlistCompleteOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(TonoColors.green)
            Text("Setlist Complete")
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
        .ignoresSafeArea()
    }

    // MARK: - Lyrics Loading

    private func loadLyricsForCurrentSong() {
        guard let song = appState.selectedSong else {
            lyricsVM.clearLyrics()
            return
        }
        lyricsVM.reloadLyrics(for: song.id)
    }

    // MARK: - Navigation

    private func handleNext() {
        guard !appState.songQueue.isEmpty else {
            showSetlistCompleteSequence()
            return
        }
        appState.advanceQueue()
        playerVM?.play()
    }

    private func handlePrevious() {
        let now = Date()
        if let last = lastLeftArrowTime, now.timeIntervalSince(last) < 3.0 {
            // Double-press within 3s — not implemented (no previous in queue model)
            // Just restart current song
            playerVM?.seek(to: 0)
            lastLeftArrowTime = nil
        } else {
            // Single press — restart current song
            playerVM?.seek(to: 0)
            lastLeftArrowTime = now
        }
    }

    private func showSetlistCompleteSequence() {
        showSetlistComplete = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard showSetlistComplete else { return }
            appState.exitGigMode()
        }
    }

    // MARK: - Chrome Auto-Hide

    private func resetChromeTimer() {
        chromeVisible = true
        chromeHideTask?.cancel()
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            chromeVisible = false
        }
    }

    private func installEventMonitor() {
        // Track mouse movement and key presses to show/hide chrome
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .keyDown]
        ) { [self] event in
            Task { @MainActor in
                if event.type == .keyDown {
                    handleKeyEvent(event)
                }
                resetChromeTimer()
            }
            // For key events we handle, return nil to swallow them
            if event.type == .keyDown {
                let keyCode = event.keyCode
                // Space (49), Left (123), Right (124), Escape (53)
                if keyCode == 49 || keyCode == 123 || keyCode == 124 || keyCode == 53 {
                    return nil
                }
            }
            return event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        switch event.keyCode {
        case 49: // Space
            playerVM?.togglePlayPause()
        case 124: // Right arrow
            handleNext()
        case 123: // Left arrow
            handlePrevious()
        case 53: // Escape
            appState.exitGigMode()
        default:
            break
        }
    }

    // MARK: - Computed helper

    private var player: PlayerViewModel? { playerVM }
}
