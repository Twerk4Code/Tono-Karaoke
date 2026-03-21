import SwiftUI

/// Large transport controls for the bottom of the Gig Mode screen.
struct GigModeTransportBar: View {
    let isPlaying: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let progress: Double
    let onPrevious: () -> Void
    let onStop: () -> Void
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onSeek: (Double) -> Void

    var body: some View {
        VStack(spacing: 10) {
            // Progress bar with time labels
            progressSection

            // Transport buttons
            transportButtons
        }
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(height: 6)

                    // Fill
                    Capsule()
                        .fill(TonoColors.cyan)
                        .frame(width: geo.size.width * max(0, min(1, progress)), height: 6)
                        .shadow(color: TonoColors.cyan.opacity(0.4), radius: 6)
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
            .frame(height: 6)

            // Time labels
            HStack {
                Text(currentTime.mmss)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
                Spacer()
                Text(duration.mmss)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }

    // MARK: - Transport Buttons

    private var transportButtons: some View {
        HStack(spacing: 40) {
            // Previous
            Button(action: onPrevious) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 60, height: 60)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Stop
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 60, height: 60)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Play / Pause — larger treatment
            Button(action: onPlayPause) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 72, height: 72)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .medium))
                        .foregroundStyle(.white)
                        .offset(x: isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: isPlaying)

            // Next
            Button(action: onNext) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .frame(width: 60, height: 60)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
