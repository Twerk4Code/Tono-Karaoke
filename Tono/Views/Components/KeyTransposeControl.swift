import SwiftUI

struct KeyTransposeControl: View {
    @Binding var semitones: Int

    private let range = -6...6

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TonoColors.textTertiary)
                .frame(width: 24)

            HStack(spacing: 2) {
                ForEach(range, id: \.self) { step in
                    stepButton(step)
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

    private func stepButton(_ step: Int) -> some View {
        let isSelected = semitones == step
        let isOrigin = step == 0
        return Button {
            semitones = step
        } label: {
            Text(label(for: step))
                .font(.system(.caption2, design: .rounded, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? .black : (isOrigin ? TonoColors.textSecondary : TonoColors.textTertiary))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? TonoColors.cyan : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
    }

    private func label(for step: Int) -> String {
        switch step {
        case 0:        return "0"
        case 1...6:    return "+\(step)"
        default:       return "\(step)"
        }
    }
}
