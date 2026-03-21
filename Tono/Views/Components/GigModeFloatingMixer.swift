import SwiftUI

/// Minimal floating mixer panel for Gig Mode, anchored near the gear button.
/// Shows vocal/instrumental volume, key transpose, and speed controls.
struct GigModeFloatingMixer: View {
    @Binding var vocalVolume: Double
    @Binding var instrumentalVolume: Double
    @Binding var pitchShiftSemitones: Int
    @Binding var playbackRate: Double
    let isRawMode: Bool
    let onDismiss: () -> Void

    /// Timer to auto-dismiss after 4 seconds of no interaction.
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("Mixer")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .padding(5)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }

            if !isRawMode {
                // Vocal volume
                mixerSlider(
                    label: "Vocal",
                    icon: "mic.fill",
                    value: $vocalVolume,
                    color: TonoColors.cyan
                )

                // Instrumental volume
                mixerSlider(
                    label: "Music",
                    icon: "music.note",
                    value: $instrumentalVolume,
                    color: TonoColors.purple
                )
            }

            // Key transpose
            HStack {
                Image(systemName: "tuningfork")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 20)
                Text("Key")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                Spacer()
                Button {
                    resetDismissTimer()
                    pitchShiftSemitones = max(-12, pitchShiftSemitones - 1)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                Text(pitchShiftSemitones >= 0 ? "+\(pitchShiftSemitones)" : "\(pitchShiftSemitones)")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, alignment: .center)

                Button {
                    resetDismissTimer()
                    pitchShiftSemitones = min(12, pitchShiftSemitones + 1)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            // Speed control
            HStack {
                Image(systemName: "speedometer")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(width: 20)
                Text("Speed")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                Spacer()
                Button {
                    resetDismissTimer()
                    playbackRate = max(0.5, (playbackRate * 10 - 1).rounded() / 10)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)

                Text(String(format: "%.1fx", playbackRate))
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, alignment: .center)

                Button {
                    resetDismissTimer()
                    playbackRate = min(2.0, (playbackRate * 10 + 1).rounded() / 10)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 260)
        .background(
            RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .background(
                    RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .clipShape(RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        .onAppear { resetDismissTimer() }
        .onDisappear { dismissTask?.cancel() }
    }

    // MARK: - Slider Row

    @ViewBuilder
    private func mixerSlider(label: String, icon: String, value: Binding<Double>, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color.opacity(0.7))
                .frame(width: 20)
            Text(label)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.6))
                .frame(width: 40, alignment: .leading)
            Slider(value: value, in: 0...1)
                .tint(color)
                .onChange(of: value.wrappedValue) { _, _ in
                    resetDismissTimer()
                }
        }
    }

    // MARK: - Auto-Dismiss

    private func resetDismissTimer() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }
}
