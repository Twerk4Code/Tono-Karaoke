import SwiftUI

/// Displays a mirrored waveform with a playback cursor and seek support.
struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    let currentTime: TimeInterval
    let duration: TimeInterval
    let onSeek: (Double) -> Void

    @State private var isHovering = false
    @State private var hoverX: CGFloat = 0

    private let barWidth: CGFloat = 2
    private let barSpacing: CGFloat = 1.5

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let totalBarWidth = barWidth + barSpacing
                let visibleBars = min(samples.count, Int(geo.size.width / totalBarWidth))
                let step = max(1, samples.count / max(1, visibleBars))

                ZStack {
                    // Waveform bars
                    HStack(alignment: .center, spacing: barSpacing) {
                        ForEach(0..<visibleBars, id: \.self) { i in
                            let sampleIndex = min(i * step, samples.count - 1)
                            let amplitude = CGFloat(samples[sampleIndex])
                            let barProgress = Double(i) / Double(max(1, visibleBars - 1))
                            let isPast = barProgress <= progress

                            WaveformBar(
                                amplitude: amplitude,
                                isPast: isPast,
                                maxHeight: geo.size.height
                            )
                        }
                    }

                    // Playback cursor
                    let cursorX = geo.size.width * max(0, min(1, progress))
                    Rectangle()
                        .fill(TonoColors.cyan)
                        .frame(width: 2)
                        .shadow(color: TonoColors.cyan.opacity(0.6), radius: 4)
                        .position(x: cursorX, y: geo.size.height / 2)

                    // Hover indicator
                    if isHovering {
                        Rectangle()
                            .fill(Color.white.opacity(0.3))
                            .frame(width: 1)
                            .position(x: hoverX, y: geo.size.height / 2)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let p = max(0, min(1, value.location.x / geo.size.width))
                            onSeek(p)
                        }
                )
                .onHover { hovering in
                    isHovering = hovering
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverX = location.x
                    case .ended:
                        isHovering = false
                    @unknown default:
                        break
                    }
                }
            }
            .frame(height: 56)

            // Time labels
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

/// A single mirrored waveform bar (top + bottom).
private struct WaveformBar: View {
    let amplitude: CGFloat
    let isPast: Bool
    let maxHeight: CGFloat

    var body: some View {
        let height = max(2, amplitude * maxHeight * 0.9)
        RoundedRectangle(cornerRadius: 1)
            .fill(isPast ? TonoColors.cyan : Color.white.opacity(0.25))
            .frame(width: 2, height: height)
    }
}

/// Placeholder for when waveform is loading.
struct WaveformPlaceholder: View {
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 56)
                ProgressView()
                    .controlSize(.small)
                    .tint(TonoColors.textTertiary)
            }
            HStack {
                Text("0:00")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(TonoColors.textTertiary)
                Spacer()
                Text("0:00")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(TonoColors.textTertiary)
            }
        }
    }
}
