import SwiftUI

struct PlaybackSpeedControl: View {
    @Binding var playbackRate: Double

    private let speeds: [Double] = [0.75, 0.85, 0.90, 0.95, 1.0, 1.05, 1.10, 1.15, 1.25, 1.5]

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TonoColors.textTertiary)
                .frame(width: 24)

            HStack(spacing: 2) {
                ForEach(speeds, id: \.self) { speed in
                    speedButton(speed)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
    }

    private func speedButton(_ speed: Double) -> some View {
        let isSelected = playbackRate == speed
        return Button {
            playbackRate = speed
        } label: {
            Text(label(for: speed))
                .font(.system(.caption2, design: .rounded, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? .black : TonoColors.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? TonoColors.cyan : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    private func label(for speed: Double) -> String {
        switch speed {
        case 0.75: return ".75×"
        case 0.85: return ".85×"
        case 0.90: return ".9×"
        case 0.95: return ".95×"
        case 1.0:  return "1×"
        case 1.05: return "1.05×"
        case 1.10: return "1.1×"
        case 1.15: return "1.15×"
        case 1.25: return "1.25×"
        case 1.5:  return "1.5×"
        default:   return "\(speed)×"
        }
    }
}
