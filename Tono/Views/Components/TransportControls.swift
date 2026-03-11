import SwiftUI

struct TransportControls: View {
    let isPlaying: Bool
    let isPitchEnabled: Bool
    let isMicMonitoring: Bool
    let onPlayPause: () -> Void
    let onStop: () -> Void
    let onPitchToggle: () -> Void
    let onMicMonitorToggle: () -> Void

    var body: some View {
        HStack(spacing: 24) {
            // Stop
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(TonoColors.textSecondary)
            }
            .buttonStyle(.plain)

            // Play / Pause
            Button(action: onPlayPause) {
                ZStack {
                    Circle()
                        .fill(TonoColors.cyan)
                        .frame(width: 52, height: 52)
                        .shadow(color: TonoColors.cyan.opacity(0.5), radius: isPlaying ? 16 : 0)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.black)
                        .offset(x: isPlaying ? 0 : 2)
                }
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: isPlaying)

            // Pitch toggle
            Button(action: onPitchToggle) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Pitch")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(isPitchEnabled ? TonoColors.green.opacity(0.2) : Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(
                                    isPitchEnabled ? TonoColors.green.opacity(0.5) : Color.white.opacity(0.15),
                                    lineWidth: 1
                                )
                        )
                )
                .foregroundStyle(isPitchEnabled ? TonoColors.green : TonoColors.textSecondary)
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: isPitchEnabled)

            // Mic monitor toggle
            Button(action: onMicMonitorToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isMicMonitoring ? "headphones" : "mic")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Mon")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(isMicMonitoring ? TonoColors.purple.opacity(0.2) : Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .strokeBorder(
                                    isMicMonitoring ? TonoColors.purple.opacity(0.5) : Color.white.opacity(0.15),
                                    lineWidth: 1
                                )
                        )
                )
                .foregroundStyle(isMicMonitoring ? TonoColors.purple : TonoColors.textSecondary)
            }
            .buttonStyle(.plain)
            .animation(.easeInOut(duration: 0.15), value: isMicMonitoring)
        }
    }
}
