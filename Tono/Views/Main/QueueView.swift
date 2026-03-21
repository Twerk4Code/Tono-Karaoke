import SwiftUI
import AppKit

struct QueueView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)
            if appState.songQueue.isEmpty {
                emptyState
            } else {
                queueList
            }
        }
        .frame(minWidth: 380, minHeight: 300)
        .background(TonoColors.surface)
    }

    private var header: some View {
        HStack {
            Text("Queue")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            if !appState.songQueue.isEmpty {
                Text("\(appState.songQueue.count)")
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(TonoColors.cyan)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(TonoColors.cyan.opacity(0.15), in: Capsule())
            }
            Spacer()
            if !appState.songQueue.isEmpty {
                Button("Clear") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        appState.clearQueue()
                    }
                }
                .buttonStyle(.plain)
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(TonoColors.red.opacity(0.8))
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(TonoColors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "list.bullet")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(TonoColors.textTertiary)
            Text("Queue is empty")
                .font(.system(.callout, design: .rounded, weight: .medium))
                .foregroundStyle(TonoColors.textSecondary)
            Text("Right-click a song to add it to the queue.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(TonoColors.textTertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }

    private var queueList: some View {
        List {
            ForEach(Array(appState.songQueue.enumerated()), id: \.element.id) { index, song in
                queueRow(song: song, index: index)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
            .onMove { source, destination in
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.moveQueueItems(from: source, to: destination)
                }
            }
            .onDelete { offsets in
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.removeFromQueue(at: offsets)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func queueRow(song: Song, index: Int) -> some View {
        HStack(spacing: 12) {
            // Position indicator
            Text("\(index + 1)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(TonoColors.textTertiary)
                .frame(width: 18, alignment: .trailing)

            // Album art thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 38, height: 38)
                if let artData = song.albumArt, let nsImage = NSImage(data: artData) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(TonoColors.textSecondary)
                }
            }

            // Song info
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
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
            }

            Spacer()

            // Remove button
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    appState.removeFromQueue(at: IndexSet(integer: index))
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TonoColors.textTertiary)
                    .padding(5)
                    .background(Color.white.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: TonoRadius.medium, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}
