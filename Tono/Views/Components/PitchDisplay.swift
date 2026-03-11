import SwiftUI

struct PitchDisplay: View {
    let reading: PitchReading
    let isActive: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Note name
            Text(reading.note)
                .font(.system(size: 48, design: .rounded).weight(.bold))
                .foregroundStyle(isActive ? pitchColor : TonoColors.textTertiary)
                .animation(.easeInOut(duration: 0.1), value: reading.note)

            // Cents bar — always present to keep layout stable
            CentsBar(cents: reading.cents)
                .opacity(isActive && reading.frequency > 0 ? 1 : 0)

            // Frequency / status — same height regardless of content
            ZStack {
                Text(String(format: "%.1f Hz", reading.frequency))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(TonoColors.textSecondary)
                    .opacity(isActive && reading.frequency > 0 ? 1 : 0)

                Text(isActive ? "Listening…" : "Pitch Off")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(TonoColors.textTertiary)
                    .opacity(isActive && reading.frequency > 0 ? 0 : 1)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous)
                        .strokeBorder(
                            isActive ? pitchColor.opacity(0.3) : Color.white.opacity(0.06),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: isActive ? pitchColor.opacity(0.15) : .clear, radius: 12)
    }

    private var pitchColor: Color {
        reading.isOnPitch ? TonoColors.green : TonoColors.red
    }
}

private struct CentsBar: View {
    let cents: Int

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 4)

                Capsule()
                    .fill(barColor)
                    .frame(width: 8, height: 12)
                    .offset(x: barOffset(width: geo.size.width))
                    .animation(.easeOut(duration: 0.08), value: cents)
            }
        }
        .frame(width: 120, height: 12)
    }

    private var barColor: Color {
        abs(cents) <= 15 ? TonoColors.green : TonoColors.red
    }

    private func barOffset(width: CGFloat) -> CGFloat {
        let normalized = Double(cents) / 50.0  // -1...+1
        return (width / 2) + (normalized * width / 2) - 4
    }
}
