import SwiftUI
import AppKit

struct SongCard: View {
    let song: Song
    let isSelected: Bool
    let onRevealFiles: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            // Album art or icon
            ZStack {
                RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                    .fill(isSelected ? TonoColors.cyan.opacity(0.2) : Color.white.opacity(0.06))
                    .frame(width: 44, height: 44)

                if let artData = song.albumArt, let nsImage = NSImage(data: artData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous))
                } else {
                    Image(systemName: song.isProcessed ? "music.note" : "clock.arrow.2.circlepath")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? TonoColors.cyan : TonoColors.textSecondary)
                }
            }

            // Info
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(isSelected ? .white : TonoColors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(song.artist)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(TonoColors.textSecondary)
                        .lineLimit(1)
                    if let dur = song.duration {
                        Text("·")
                            .foregroundStyle(TonoColors.textTertiary)
                        Text(dur.mmss)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(TonoColors.textTertiary)
                    }
                }
                if song.hasStemSeparation {
                    HStack(spacing: 3) {
                        Image(systemName: "waveform.path.ecg.rectangle")
                            .font(.system(size: 8, weight: .bold))
                        Text("STEMS")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .tracking(0.8)
                    }
                    .foregroundStyle(TonoColors.cyan)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(TonoColors.cyan.opacity(0.15))
                    )
                }
            }

            Spacer()

            HStack(spacing: 10) {
                Button {
                    onRevealFiles()
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(TonoColors.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Show stored files in Finder")

                // Delete button — reveals on hover
                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(TonoColors.red.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
            .opacity(isHovered ? 1 : 0.6)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: TonoRadius.medium, style: .continuous)
                .fill(isSelected ? TonoColors.cyan.opacity(0.12) : isHovered ? Color.white.opacity(0.04) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: TonoRadius.medium, style: .continuous)
                        .strokeBorder(
                            isSelected ? TonoColors.cyan.opacity(0.3) : Color.clear,
                            lineWidth: 1
                        )
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: TonoRadius.medium, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}
