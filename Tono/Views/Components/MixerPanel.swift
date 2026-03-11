import SwiftUI

struct MixerPanel: View {
    @Binding var vocalVolume: Double
    @Binding var instrumentalVolume: Double
    @Binding var showEffects: Bool
    var effectsActive: Bool
    var isRawMode: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("MIXER")
                    .font(.system(.caption2, design: .rounded, weight: .bold))
                    .foregroundStyle(TonoColors.textTertiary)
                    .tracking(2)
                Spacer()
                // FX toggle — cyan-tinted when panel is open or any effect is active
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showEffects.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.below.rectangle")
                            .font(.system(size: 11, weight: .semibold))
                        Text("FX")
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .tracking(1)
                    }
                    .foregroundStyle(showEffects || effectsActive ? TonoColors.cyan : TonoColors.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                            .fill(showEffects || effectsActive
                                  ? TonoColors.cyan.opacity(0.15)
                                  : Color.white.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
            }

            if !isRawMode {
                stemChannel(
                    icon: "music.mic",
                    label: "Vocals",
                    color: TonoColors.cyan,
                    value: $vocalVolume
                )
            }

            stemChannel(
                icon: "guitars",
                label: isRawMode ? "Track" : "Instrumental",
                color: TonoColors.purple,
                value: $instrumentalVolume
            )
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func stemChannel(icon: String, label: String, color: Color, value: Binding<Double>) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                    .fill(color.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(label)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(Int(value.wrappedValue * 100))%")
                        .font(.system(.caption, design: .monospaced, weight: .bold))
                        .foregroundStyle(color)
                        .frame(minWidth: 38, alignment: .trailing)
                }

                Slider(value: value, in: 0...1)
                    .tint(color)
            }
        }
    }
}
