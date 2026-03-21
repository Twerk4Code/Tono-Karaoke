import SwiftUI

/// Stage-scale lyrics display for Gig Mode.
/// Renders lyrics at large font sizes optimized for on-stage readability.
struct GigModeLyricsView: View {
    let lyrics: [Lyric]
    let currentIndex: Int
    let onTap: () -> Void

    var body: some View {
        Group {
            if lyrics.isEmpty {
                emptyState
            } else {
                lyricsScroll
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.quote")
                .font(.system(size: 48, weight: .ultraLight))
                .foregroundStyle(Color.white.opacity(0.15))
            Text("No lyrics available")
                .font(.system(.title3, design: .rounded, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Lyrics Scroll

    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    // Top spacer so the first line can scroll to center
                    Color.clear.frame(height: 300)

                    ForEach(Array(lyrics.enumerated()), id: \.element.id) { index, lyric in
                        lyricLine(lyric: lyric, index: index)
                    }

                    // Bottom spacer
                    Color.clear.frame(height: 300)
                }
                .padding(.horizontal, 48)
            }
            .onChange(of: currentIndex) { _, newIndex in
                guard newIndex >= 0, newIndex < lyrics.count else { return }
                withAnimation(.spring(duration: 0.35, bounce: 0.1)) {
                    proxy.scrollTo(lyrics[newIndex].id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func lyricLine(lyric: Lyric, index: Int) -> some View {
        let isCurrent = index == currentIndex
        let isPast = index < currentIndex
        let isNext = !isPast && !isCurrent

        Text(lyric.text)
            .font(.system(
                size: isCurrent ? 78 : (isNext && index <= currentIndex + 2 ? 40 : 28),
                weight: isCurrent ? .bold : .regular,
                design: .rounded
            ))
            .foregroundStyle(lineColor(isCurrent: isCurrent, isPast: isPast))
            .shadow(color: isCurrent ? TonoColors.cyan.opacity(0.25) : .clear, radius: 12, y: 0)
            .multilineTextAlignment(.center)
            .padding(.vertical, isCurrent ? 20 : 8)
            .frame(maxWidth: .infinity)
            .id(lyric.id)
            .animation(.spring(duration: 0.35, bounce: 0.1), value: isCurrent)
    }

    private func lineColor(isCurrent: Bool, isPast: Bool) -> Color {
        if isCurrent {
            return .white
        } else if isPast {
            return .white.opacity(0.25)
        } else {
            return TonoColors.cyan.opacity(0.5)
        }
    }
}
