import SwiftUI
import MetalKit

/// Right-sidebar lyrics panel with real-time line highlighting, auto-scroll, and manual search.
struct LyricsDisplay: View {
    let songID: UUID
    /// Pass the song's lrcURL so the view reloads when the background fetch completes.
    let lrcURL: URL?
    let currentTime: TimeInterval
    let isPlaying: Bool
    let songTitle: String
    let songArtist: String
    /// Set to true while the search text field is focused so the caller can suppress hotkeys.
    @Binding var isSearchFieldFocused: Bool

    @Environment(AppState.self) private var appState
    @State private var vm = LyricsViewModel()
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Divider()
                .opacity(0.08)

            ZStack {
                lyricsPanelBackground

                if vm.isSearching {
                    searchView
                } else if vm.lyrics.isEmpty {
                    emptyState
                } else {
                    lyricsScroll
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            vm.loadLyrics(for: songID)
        }
        .onChange(of: songID) { _, newID in
            vm.cancelSearch()
            vm.loadLyrics(for: newID)
        }
        // Reload when the background fetch finishes and saves the .lrc file
        .onChange(of: lrcURL) { _, _ in
            vm.reloadLyrics(for: songID)
        }
        .onChange(of: currentTime) { _, time in
            if isPlaying {
                vm.update(currentTime: time)
            }
        }
        // Sync internal focus state out to the caller
        .onChange(of: searchFocused) { _, focused in
            isSearchFieldFocused = focused
        }
        // Auto-focus the text field when search mode opens
        .onChange(of: vm.isSearching) { _, searching in
            if searching {
                // Small delay so the field is in the view hierarchy before focusing
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    searchFocused = true
                }
            } else {
                searchFocused = false
                isSearchFieldFocused = false
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("LYRICS")
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(TonoColors.textTertiary)
                .tracking(1.5)

            Spacer(minLength: 8)

            if movieModeEnabled {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles.tv")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Movie On")
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                }
                .foregroundStyle(TonoColors.cyan.opacity(0.92))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(TonoColors.cyan.opacity(0.14))
                )
            }

            Button {
                if vm.isSearching {
                    vm.cancelSearch()
                } else {
                    vm.beginSearch(songTitle: songTitle, songArtist: songArtist)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: vm.isSearching ? "xmark" : "magnifyingglass")
                        .font(.system(size: 10, weight: .semibold))
                    Text(vm.isSearching ? "Close" : "Change")
                        .font(.system(.caption2, design: .rounded, weight: .medium))
                }
                .foregroundStyle(TonoColors.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Background Layer

    private var lyricsPanelBackground: some View {
        ZStack {
            TonoColors.surface.opacity(movieModeEnabled ? 0.22 : 0.5)

            if movieModeEnabled {
                ReactiveVisualizerBackgroundView(
                    analyzer: appState.playbackVisualizer,
                    intensity: appState.settings.visualizer.intensity
                )
                .opacity(0.70)

                LinearGradient(
                    colors: [
                        Color.black.opacity(appState.settings.visualizer.readabilityScrim * 0.95),
                        Color.black.opacity(appState.settings.visualizer.readabilityScrim * 0.55),
                        Color.black.opacity(appState.settings.visualizer.readabilityScrim * 0.95)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blendMode(.multiply)
                .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: movieModeEnabled)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(TonoColors.textTertiary)
            Text("Lyrics not available")
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(TonoColors.textSecondary)
            Text("Sing freely!")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(TonoColors.textTertiary)

            Button {
                vm.beginSearch(songTitle: songTitle, songArtist: songArtist)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Search Lyrics")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                }
                .foregroundStyle(TonoColors.cyan)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                        .fill(TonoColors.cyan.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Search View

    private var searchView: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(TonoColors.textSecondary)

                TextField("Song title or artist...", text: $vm.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.white)
                    .focused($searchFocused)
                    .onSubmit { vm.performSearch() }

                if !vm.searchQuery.isEmpty {
                    Button {
                        vm.searchQuery = ""
                        vm.searchResults = []
                        vm.searchError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(TonoColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 14)
            .padding(.top, 14)

            // Search button
            Button { vm.performSearch() } label: {
                HStack(spacing: 6) {
                    if vm.isLoadingSearch {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.7)
                            .tint(.white)
                    }
                    Text(vm.isLoadingSearch ? "Searching..." : "Search")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                        .fill(TonoColors.cyan.opacity(vm.isLoadingSearch ? 0.15 : 0.25))
                )
            }
            .buttonStyle(.plain)
            .disabled(vm.isLoadingSearch || vm.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            .padding(.horizontal, 14)
            .padding(.top, 8)

            Divider()
                .opacity(0.12)
                .padding(.top, 12)

            // Results area
            Group {
                if let error = vm.searchError {
                    Spacer()
                    Text(error)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(TonoColors.textTertiary)
                    Spacer()
                } else if vm.searchResults.isEmpty && !vm.isLoadingSearch {
                    Spacer()
                    Text("Type a title or artist name\nthen press Search")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(TonoColors.textTertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                } else if !vm.searchResults.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(vm.searchResults) { result in
                                searchResultRow(result)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                    }
                } else {
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func searchResultRow(_ result: LyricsSearchResult) -> some View {
        Button {
            vm.selectResult(result, for: songID)
            appState.assignLyrics(to: songID)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 6) {
                    Text(result.trackName)
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    if result.hasSyncedLyrics {
                        Text("SYNCED")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(TonoColors.cyan)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(TonoColors.cyan.opacity(0.15))
                            )
                            .padding(.top, 2)
                    }
                }

                HStack {
                    Text(result.artistName.isEmpty ? "Unknown Artist" : result.artistName)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(TonoColors.textSecondary)
                        .lineLimit(1)

                    Spacer()

                    if result.duration > 0 {
                        Text(result.duration.mmss)
                            .font(.system(.caption2, design: .rounded).monospacedDigit())
                            .foregroundStyle(TonoColors.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Lyrics Scroll

    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    // Top spacer so first line can scroll to center
                    Color.clear.frame(height: 120)

                    ForEach(Array(vm.lyrics.enumerated()), id: \.element.id) { index, lyric in
                        lyricRow(lyric: lyric, index: index)
                    }

                    // Bottom spacer
                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: vm.currentIndex) { _, newIndex in
                guard newIndex >= 0, newIndex < vm.lyrics.count else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo(vm.lyrics[newIndex].id, anchor: .center)
                }
            }
        }
    }

    private func lyricRow(lyric: Lyric, index: Int) -> some View {
        let isCurrent = index == vm.currentIndex
        let nonCurrentOpacity = movieModeEnabled ? 0.62 : 0.35
        let currentBackground = movieModeEnabled ? TonoColors.cyan.opacity(0.14) : TonoColors.cyan.opacity(0.08)
        return Text(lyric.text)
            .font(.system(isCurrent ? .body : .callout, design: .rounded,
                          weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(isCurrent ? TonoColors.cyan : Color.white.opacity(nonCurrentOpacity))
            .shadow(color: isCurrent ? TonoColors.cyan.opacity(movieModeEnabled ? 0.18 : 0.08) : .clear, radius: 5, y: 0)
            .multilineTextAlignment(.center)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(
                isCurrent
                    ? currentBackground
                        .clipShape(RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous))
                    : nil
            )
            .id(lyric.id)
            .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }

    private var movieModeEnabled: Bool {
        appState.settings.visualizer.isEnabled &&
            appState.settings.visualizer.placement == .lyricsPane &&
            appState.settings.visualizer.style == .appleMovie
    }
}

struct ReactiveVisualizerBackgroundView: View {
    let analyzer: PlaybackVisualizerAnalyzer
    let intensity: Double

    private static let hasMetalDevice = MTLCreateSystemDefaultDevice() != nil

    var body: some View {
        Group {
            if Self.hasMetalDevice {
                MetalReactiveVisualizerView(analyzer: analyzer, intensity: intensity)
            } else {
                AppleMovieFallbackView(analyzer: analyzer, intensity: intensity)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MetalReactiveVisualizerView: NSViewRepresentable {
    let analyzer: PlaybackVisualizerAnalyzer
    let intensity: Double

    final class Coordinator {
        var renderer: MetalReactiveVisualizerRenderer?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 120
        view.autoResizeDrawable = true
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = .none

        if let device = view.device,
           let renderer = MetalReactiveVisualizerRenderer(
               device: device,
               colorPixelFormat: view.colorPixelFormat,
               analyzer: analyzer,
               intensity: Float(intensity)
           ) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
        } else {
            view.delegate = nil
        }

        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        let fps = targetFPS(for: nsView)
        if nsView.preferredFramesPerSecond != fps {
            nsView.preferredFramesPerSecond = fps
        }
        context.coordinator.renderer?.setTargetFPS(Float(fps))
        context.coordinator.renderer?.setAnalyzer(analyzer)
        context.coordinator.renderer?.setIntensity(Float(intensity))
    }

    private func targetFPS(for view: MTKView) -> Int {
        let maxDisplayFPS = view.window?.screen?.maximumFramesPerSecond ?? 120
        return max(60, min(120, maxDisplayFPS))
    }
}

private final class MetalReactiveVisualizerRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var resolution: SIMD2<Float>
        var time: Float
        var intensity: Float
        var overall: Float
        var bass: Float
        var mid: Float
        var treble: Float
        var beat: Float
        var flux: Float
        var stereo: Float
    }

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private weak var analyzer: PlaybackVisualizerAnalyzer?
    private var intensity: Float
    private let startTime = CACurrentMediaTime()
    private var smoothedFeatures: PlaybackVisualizerFeatures = .zero
    private var lastFrameTime = CACurrentMediaTime()
    private var targetFPS: Float = 120

    init?(
        device: MTLDevice,
        colorPixelFormat: MTLPixelFormat,
        analyzer: PlaybackVisualizerAnalyzer,
        intensity: Float
    ) {
        guard let commandQueue = device.makeCommandQueue() else { return nil }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
#if DEBUG
            print("[ReactiveVisualizer][Metal] Shader compilation failed: \(error)")
#endif
            return nil
        }

        guard let vertexFunction = library.makeFunction(name: "visualizerVertex"),
              let fragmentFunction = library.makeFunction(name: "visualizerFragment") else {
#if DEBUG
            print("[ReactiveVisualizer][Metal] Missing shader entry points")
#endif
            return nil
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat

        do {
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
#if DEBUG
            print("[ReactiveVisualizer][Metal] Pipeline creation failed: \(error)")
#endif
            return nil
        }

        self.commandQueue = commandQueue
        self.analyzer = analyzer
        self.intensity = max(0.15, min(0.8, intensity))
        super.init()
    }

    func setAnalyzer(_ analyzer: PlaybackVisualizerAnalyzer) {
        self.analyzer = analyzer
    }

    func setIntensity(_ intensity: Float) {
        self.intensity = max(0.15, min(0.8, intensity))
    }

    func setTargetFPS(_ fps: Float) {
        self.targetFPS = max(60, min(120, fps))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        _ = size
    }

    func draw(in view: MTKView) {
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let now = CACurrentMediaTime()
        let deltaTime = Float(max(1.0 / 240.0, min(1.0 / 20.0, now - lastFrameTime)))
        lastFrameTime = now

        let snapshot = analyzer?.latestFeaturesSnapshot() ?? .zero
        smoothedFeatures = smoothSnapshot(
            current: smoothedFeatures,
            target: snapshot,
            deltaTime: deltaTime
        )

        var uniforms = Uniforms(
            resolution: SIMD2<Float>(
                Float(max(1, view.drawableSize.width)),
                Float(max(1, view.drawableSize.height))
            ),
            time: Float(now - startTime),
            intensity: intensity,
            overall: smoothedFeatures.overallEnergy,
            bass: smoothedFeatures.bassEnergy,
            mid: smoothedFeatures.midEnergy,
            treble: smoothedFeatures.trebleEnergy,
            beat: smoothedFeatures.beatImpulse,
            flux: smoothedFeatures.spectralFlux,
            stereo: smoothedFeatures.stereoWidth
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func smoothSnapshot(
        current: PlaybackVisualizerFeatures,
        target: PlaybackVisualizerFeatures,
        deltaTime: Float
    ) -> PlaybackVisualizerFeatures {
        let fpsScale = max(0.7, min(1.6, targetFPS / 120))
        let bass = smoothValue(
            current: current.bassEnergy,
            target: target.bassEnergy,
            riseRate: 10.0 * fpsScale,
            fallRate: 7.5 * fpsScale,
            deltaTime: deltaTime
        )
        let mid = smoothValue(
            current: current.midEnergy,
            target: target.midEnergy,
            riseRate: 9.0 * fpsScale,
            fallRate: 7.0 * fpsScale,
            deltaTime: deltaTime
        )
        let treble = smoothValue(
            current: current.trebleEnergy,
            target: target.trebleEnergy,
            riseRate: 9.5 * fpsScale,
            fallRate: 7.2 * fpsScale,
            deltaTime: deltaTime
        )
        let overall = smoothValue(
            current: current.overallEnergy,
            target: target.overallEnergy,
            riseRate: 9.0 * fpsScale,
            fallRate: 7.0 * fpsScale,
            deltaTime: deltaTime
        )
        let beat = smoothValue(
            current: current.beatImpulse,
            target: target.beatImpulse,
            riseRate: 11.0 * fpsScale,
            fallRate: 8.0 * fpsScale,
            deltaTime: deltaTime
        )
        let flux = smoothValue(
            current: current.spectralFlux,
            target: target.spectralFlux,
            riseRate: 10.0 * fpsScale,
            fallRate: 7.8 * fpsScale,
            deltaTime: deltaTime
        )
        let stereo = smoothValue(
            current: current.stereoWidth,
            target: target.stereoWidth,
            riseRate: 11.0 * fpsScale,
            fallRate: 8.0 * fpsScale,
            deltaTime: deltaTime
        )
        return PlaybackVisualizerFeatures(
            overallEnergy: overall,
            bassEnergy: bass,
            midEnergy: mid,
            trebleEnergy: treble,
            beatImpulse: beat,
            spectralFlux: flux,
            stereoWidth: stereo,
            isSilent: overall < 0.015 && beat < 0.02
        )
    }

    private func smoothValue(
        current: Float,
        target: Float,
        riseRate: Float,
        fallRate: Float,
        deltaTime: Float
    ) -> Float {
        let rate = target > current ? riseRate : fallRate
        let alpha = 1 - expf(-rate * deltaTime)
        return current + (target - current) * alpha
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
        float2 resolution;
        float time;
        float intensity;
        float overall;
        float bass;
        float mid;
        float treble;
        float beat;
        float flux;
        float stereo;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut visualizerVertex(uint vertexID [[vertex_id]]) {
        float2 positions[3];
        positions[0] = float2(-1.0, -1.0);
        positions[1] = float2(3.0, -1.0);
        positions[2] = float2(-1.0, 3.0);

        VertexOut out;
        float2 pos = positions[vertexID];
        out.position = float4(pos, 0.0, 1.0);
        out.uv = pos * 0.5 + 0.5;
        return out;
    }

    float lineGlow(float y, float center, float width) {
        return exp(-abs(y - center) * width);
    }

    fragment float4 visualizerFragment(
        VertexOut in [[stage_in]],
        constant Uniforms& u [[buffer(0)]]
    ) {
        constexpr float PI = 3.14159265359;
        float2 uv = in.uv;
        float t = u.time;
        float intensity = clamp(u.intensity, 0.15, 0.8);
        float strength = 0.28 + intensity * 0.56;
        float motion = clamp(0.14 + u.overall * 0.86 + u.beat * 0.45 + u.flux * 0.35, 0.18, 1.0);

        float3 c0 = float3(0.07, 0.09, 0.18);
        float3 c1 = float3(0.03, 0.13, 0.21);
        float3 c2 = float3(0.12, 0.06, 0.18);
        float gradDrift = 0.06 * sin(t * 0.19 + uv.x * 2.3);
        float gradMix = clamp(uv.y + gradDrift, 0.0, 1.0);
        float3 color = mix(c0, c1, gradMix);
        color = mix(color, c2, smoothstep(0.55, 1.0, uv.y));

        float2 centerA = float2(
            0.5 + 0.30 * sin(t * 0.22),
            0.5 + 0.22 * cos(t * 0.16)
        );
        float2 centerB = float2(
            0.5 + 0.26 * cos(t * 0.17 + 1.5),
            0.5 + 0.24 * sin(t * 0.14 + 0.7)
        );
        float glowA = exp(-distance(uv, centerA) * 3.8) * (0.46 * strength);
        float glowB = exp(-distance(uv, centerB) * 3.6) * (0.42 * strength);
        color += float3(0.00, 0.58, 0.95) * glowA;
        color += float3(0.55, 0.25, 0.95) * glowB;

        float beatDrive = clamp(u.beat * 0.75 + u.flux * 0.15, 0.0, 1.0);
        float bassDrive = clamp(u.bass * 0.85, 0.0, 1.0);
        float topBand = clamp(u.treble * 0.72 + u.mid * 0.24 + u.flux * 0.10, 0.0, 1.0);
        float bottomBand = clamp(u.bass * 0.78 + u.mid * 0.20 + beatDrive * 0.08, 0.0, 1.0);
        float leftWeight = pow(clamp(1.0 - uv.x, 0.0, 1.0), 1.25);
        float rightWeight = pow(clamp(uv.x, 0.0, 1.0), 1.25);
        float topLocalDrive = clamp(topBand * (0.62 + 0.38 * rightWeight) + u.flux * rightWeight * 0.25, 0.0, 1.0);
        float bottomLocalDrive = clamp(bottomBand * (0.62 + 0.38 * leftWeight) + beatDrive * leftWeight * 0.30, 0.0, 1.0);
        float beatPulse = 1.0 + beatDrive * 0.42;

        float topAmp = (0.016 + 0.050 * motion) * (0.78 + strength * 0.28 + topBand * 0.72) * beatPulse;
        float bottomAmp = (0.016 + 0.056 * motion) * (0.80 + strength * 0.28 + bottomBand * 0.76) * beatPulse;
        float topAmpLocal = topAmp * (0.72 + topLocalDrive * 0.45);
        float bottomAmpLocal = bottomAmp * (0.72 + bottomLocalDrive * 0.48);
        float topSpeed = 0.62 + beatDrive * 0.52 + u.treble * 0.34;
        float bottomSpeed = 0.60 + beatDrive * 0.58 + bassDrive * 0.36;
        float topFrequency = 3.2 + topBand * 1.4;
        float bottomFrequency = 3.0 + bottomBand * 1.6;

        float topY =
            0.20 + u.treble * 0.04 +
            sin(uv.x * PI * topFrequency + t * topSpeed) * topAmpLocal +
            cos(uv.x * PI * (7.6 + u.mid * 2.0) - t * (topSpeed * 0.58) + u.stereo * 1.8) *
                topAmpLocal * (0.18 + topLocalDrive * 0.20);
        float bottomY =
            0.80 - u.bass * 0.04 +
            sin(uv.x * PI * bottomFrequency - t * bottomSpeed + 1.6) * bottomAmpLocal +
            cos(uv.x * PI * (7.2 + u.mid * 1.8) + t * (bottomSpeed * 0.54) - u.stereo * 1.4) *
                bottomAmpLocal * (0.16 + bottomLocalDrive * 0.22);

        float topGlowWidth = max(35.0, 74.0 - topLocalDrive * 18.0 - beatDrive * 10.0);
        float topCoreWidth = max(90.0, 180.0 - topLocalDrive * 28.0 - beatDrive * 14.0);
        float bottomGlowWidth = max(35.0, 74.0 - bottomLocalDrive * 19.0 - beatDrive * 10.0);
        float bottomCoreWidth = max(90.0, 180.0 - bottomLocalDrive * 30.0 - beatDrive * 14.0);

        float topGlow = lineGlow(uv.y, topY, topGlowWidth);
        float topCore = lineGlow(uv.y, topY, topCoreWidth);
        float bottomGlow = lineGlow(uv.y, bottomY, bottomGlowWidth);
        float bottomCore = lineGlow(uv.y, bottomY, bottomCoreWidth);

        color += float3(0.25, 0.62, 1.00) * topGlow * (0.14 + motion * 0.12 + topLocalDrive * 0.12 + beatDrive * 0.08);
        color += float3(0.36, 0.78, 1.00) * topCore * (0.30 + motion * 0.12 + topLocalDrive * 0.15 + beatDrive * 0.10);
        color += float3(0.58, 0.32, 1.00) * bottomGlow * (0.14 + motion * 0.12 + bottomLocalDrive * 0.12 + beatDrive * 0.08);
        color += float3(0.75, 0.52, 1.00) * bottomCore * (0.30 + motion * 0.12 + bottomLocalDrive * 0.15 + beatDrive * 0.10);

        float trailAmp = 0.010 + 0.040 * motion + 0.024 * u.beat;
        float trailA = lineGlow(
            uv.y,
            0.34 +
                sin((uv.x + 0.12) * (PI * 6.4) + t * (0.90 + u.beat * 1.10)) * trailAmp +
                cos((uv.x + 0.08) * (PI * 3.6) - t * 0.62) * trailAmp * 0.50,
            170.0
        );
        float trailB = lineGlow(
            uv.y,
            0.56 +
                sin((uv.x + 0.38) * (PI * 7.6) - t * (1.00 + u.flux * 1.20)) * trailAmp * 0.88 +
                cos((uv.x + 0.31) * (PI * 4.2) + t * 0.58) * trailAmp * 0.52,
            190.0
        );
        float trailC = lineGlow(
            uv.y,
            0.74 +
                sin((uv.x + 0.61) * (PI * 8.2) + t * (1.08 + u.beat * 0.90)) * trailAmp * 0.86 +
                cos((uv.x + 0.53) * (PI * 4.8) - t * 0.66) * trailAmp * 0.48,
            200.0
        );
        color += float3(0.18, 0.72, 1.00) * trailA * (0.04 + motion * 0.07 + u.beat * 0.06);
        color += float3(0.56, 0.42, 1.00) * trailB * (0.04 + motion * 0.07 + u.flux * 0.05);
        color += float3(0.22, 0.88, 0.95) * trailC * (0.03 + motion * 0.05 + u.beat * 0.04);

        float vignette = smoothstep(0.92, 0.25, distance(uv, float2(0.5, 0.5)));
        color *= 0.84 + vignette * 0.16;
        color = clamp(color, 0.0, 1.45);
        return float4(color, 1.0);
    }
    """
}

struct AppleMovieFallbackView: View {
    let analyzer: PlaybackVisualizerAnalyzer
    let intensity: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let features = analyzer.latestFeaturesSnapshot()
            let clampedIntensity = max(0.15, min(0.8, intensity))
            let strength = 0.28 + clampedIntensity * 0.56
            let energy = Double(features.overallEnergy)
            let bass = Double(features.bassEnergy)
            let mid = Double(features.midEnergy)
            let treble = Double(features.trebleEnergy)
            let beat = Double(features.beatImpulse)
            let flux = Double(features.spectralFlux)
            let stereo = Double(features.stereoWidth)
            let motion = max(0.18, min(1, 0.14 + energy * 0.86 + beat * 0.45 + flux * 0.35))

            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.07, green: 0.09, blue: 0.18),
                        Color(red: 0.03, green: 0.13, blue: 0.21),
                        Color(red: 0.12, green: 0.06, blue: 0.18)
                    ],
                    startPoint: UnitPoint(x: 0.12 + 0.10 * sin(t * 0.19), y: 0.05),
                    endPoint: UnitPoint(x: 0.88, y: 0.92 + 0.04 * cos(t * 0.13))
                )

                RadialGradient(
                    colors: [
                        Color.cyan.opacity(0.46 * strength),
                        Color.cyan.opacity(0)
                    ],
                    center: UnitPoint(
                        x: 0.5 + 0.30 * sin(t * 0.22),
                        y: 0.5 + 0.22 * cos(t * 0.16)
                    ),
                    startRadius: 8,
                    endRadius: 340
                )

                RadialGradient(
                    colors: [
                        Color.purple.opacity(0.42 * strength),
                        Color.blue.opacity(0)
                    ],
                    center: UnitPoint(
                        x: 0.5 + 0.26 * cos(t * 0.17 + 1.5),
                        y: 0.5 + 0.24 * sin(t * 0.14 + 0.7)
                    ),
                    startRadius: 8,
                    endRadius: 360
                )

                Canvas(opaque: false, rendersAsynchronously: true) { context, size in
                    drawBackdropWaves(
                        context: &context,
                        size: size,
                        time: t,
                        strength: strength,
                        motion: motion,
                        beat: beat,
                        bass: bass,
                        mid: mid,
                        treble: treble,
                        stereo: stereo
                    )
                    drawNeonTrails(
                        context: &context,
                        size: size,
                        time: t,
                        strength: strength,
                        motion: motion,
                        beat: beat
                    )
                    drawParticles(
                        context: &context,
                        size: size,
                        time: t,
                        strength: strength,
                        motion: motion,
                        beat: beat
                    )
                }
                .blendMode(.plusLighter)
            }
            .saturation(1.18 + strength * 0.10)
            .blur(radius: 10)
        }
        .allowsHitTesting(false)
    }

    private func drawBackdropWaves(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        strength: Double,
        motion: Double,
        beat: Double,
        bass: Double,
        mid: Double,
        treble: Double,
        stereo: Double
    ) {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let segments = 56
        let topBandDrive = max(0, min(1, treble * 0.68 + mid * 0.20 + beat * 0.16))
        let bottomBandDrive = max(0, min(1, bass * 0.70 + mid * 0.18 + beat * 0.18))
        let beatPulse = 1.0 + beat * 0.95
        let topAmplitude = (10 + height * 0.048 * motion) * (0.74 + strength * 0.40 + topBandDrive * 1.08) * beatPulse
        let bottomAmplitude = (10 + height * 0.052 * motion) * (0.76 + strength * 0.40 + bottomBandDrive * 1.12) * beatPulse
        let topSpeed = 0.84 + beat * 1.22 + treble * 0.78
        let bottomSpeed = 0.80 + beat * 1.30 + bass * 0.84
        let topFrequency = 4.0 + topBandDrive * 2.2
        let bottomFrequency = 3.8 + bottomBandDrive * 2.3

        var topPath = Path()
        for step in 0...segments {
            let progress = Double(step) / Double(segments)
            let x = width * progress
            let primary = sin(progress * .pi * topFrequency + time * topSpeed) * topAmplitude
            let detail = cos(progress * .pi * (7.6 + mid * 2.0) - time * (topSpeed * 0.58) + stereo * 1.8) *
                topAmplitude * (0.20 + topBandDrive * 0.18)
            let y = height * (0.20 + treble * 0.04) + primary + detail
            if step == 0 {
                topPath.move(to: CGPoint(x: x, y: y))
            } else {
                topPath.addLine(to: CGPoint(x: x, y: y))
            }
        }

        var bottomPath = Path()
        for step in 0...segments {
            let progress = Double(step) / Double(segments)
            let x = width * progress
            let primary = sin(progress * .pi * bottomFrequency - time * bottomSpeed + 1.6) * bottomAmplitude
            let detail = cos(progress * .pi * (7.2 + mid * 1.8) + time * (bottomSpeed * 0.54) - stereo * 1.4) *
                bottomAmplitude * (0.18 + bottomBandDrive * 0.20)
            let y = height * (0.80 - bass * 0.04) + primary + detail
            if step == 0 {
                bottomPath.move(to: CGPoint(x: x, y: y))
            } else {
                bottomPath.addLine(to: CGPoint(x: x, y: y))
            }
        }

        let blueGlow = Color(red: 0.25, green: 0.62, blue: 1.0).opacity(0.15 + motion * 0.14 + topBandDrive * 0.16 + beat * 0.12)
        let blueCore = Color(red: 0.36, green: 0.78, blue: 1.0).opacity(0.34 + motion * 0.16 + topBandDrive * 0.20 + beat * 0.14)
        let purpleGlow = Color(red: 0.58, green: 0.32, blue: 1.0).opacity(0.15 + motion * 0.14 + bottomBandDrive * 0.16 + beat * 0.12)
        let purpleCore = Color(red: 0.75, green: 0.52, blue: 1.0).opacity(0.33 + motion * 0.16 + bottomBandDrive * 0.20 + beat * 0.14)
        let topGlowWidth = 5.4 + topBandDrive * 2.2 + beat * 1.8
        let topCoreWidth = 1.5 + topBandDrive * 0.9 + beat * 0.45
        let bottomGlowWidth = 5.2 + bottomBandDrive * 2.3 + beat * 1.8
        let bottomCoreWidth = 1.45 + bottomBandDrive * 0.95 + beat * 0.45

        context.stroke(topPath, with: .color(blueGlow), style: StrokeStyle(lineWidth: topGlowWidth, lineCap: .round, lineJoin: .round))
        context.stroke(topPath, with: .color(blueCore), style: StrokeStyle(lineWidth: topCoreWidth, lineCap: .round, lineJoin: .round))
        context.stroke(bottomPath, with: .color(purpleGlow), style: StrokeStyle(lineWidth: bottomGlowWidth, lineCap: .round, lineJoin: .round))
        context.stroke(bottomPath, with: .color(purpleCore), style: StrokeStyle(lineWidth: bottomCoreWidth, lineCap: .round, lineJoin: .round))
    }

    private func drawNeonTrails(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        strength: Double,
        motion: Double,
        beat: Double
    ) {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let lanes = 6
        let steps = 42
        for lane in 0..<lanes {
            let laneProgress = Double(lane) / Double(max(1, lanes - 1))
            let baseY = height * (0.14 + 0.72 * laneProgress)
            let amplitude = (10 + height * 0.11 * motion) * (0.72 + strength * 0.42 + beat * 0.30)
            let freq = 4.8 + laneProgress * 3.4
            let speed = 0.9 + laneProgress * 0.8
            let phase = Double(lane) * 1.2

            var path = Path()
            for step in 0...steps {
                let progress = Double(step) / Double(steps)
                let x = width * progress
                let yOffset =
                    sin(progress * .pi * freq + time * speed + phase) * amplitude +
                    cos(progress * .pi * (freq * 0.5) - time * (speed * 0.6) - phase * 0.7) * amplitude * 0.35
                let y = baseY + yOffset
                if step == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            let hue = wrappedHue(0.53 + laneProgress * 0.34 + sin(time * 0.08 + phase) * 0.04)
            let glowColor = Color(hue: hue, saturation: 0.9, brightness: 1.0).opacity(0.11 + motion * 0.12 + beat * 0.10)
            let coreColor = Color(hue: hue, saturation: 0.72, brightness: 1.0).opacity(0.28 + motion * 0.24 + beat * 0.14)

            context.stroke(path, with: .color(glowColor), style: StrokeStyle(lineWidth: 4.6, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(coreColor), style: StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawParticles(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        strength: Double,
        motion: Double,
        beat: Double
    ) {
        let width = max(1, size.width)
        let height = max(1, size.height)
        let count = Int(48 + motion * 88)
        for index in 0..<count {
            let seed = Double(index) + 1
            let radial = 0.26 + pseudoRandom(seed * 0.73) * 0.62
            let swirl = time * (0.26 + pseudoRandom(seed * 1.37) * 0.68) + pseudoRandom(seed * 2.11) * .pi * 2
            let wobble = sin(time * 0.51 + seed * 0.31) * 0.34
            let x = width * (0.5 + cos(swirl + wobble) * radial * 0.48)
            let y = height * (0.5 + sin(swirl * 1.07 - wobble * 0.8) * radial * 0.48)
            let sizeBase = 1.2 + pseudoRandom(seed * 2.91) * 2.6
            let radius = sizeBase + motion * 1.7 + beat * 2.6
            let alpha = 0.08 + strength * 0.14 + beat * 0.10
            let hue = wrappedHue(0.55 + pseudoRandom(seed * 1.93) * 0.32 + sin(time * 0.06 + seed) * 0.02)
            let color = Color(hue: hue, saturation: 0.86, brightness: 1.0).opacity(alpha)
            let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color))
        }
    }

    private func wrappedHue(_ value: Double) -> Double {
        let mod = value.truncatingRemainder(dividingBy: 1)
        return mod >= 0 ? mod : mod + 1
    }

    private func pseudoRandom(_ seed: Double) -> Double {
        let x = sin(seed * 12.9898) * 43758.5453
        return x - floor(x)
    }
}
