import Foundation

/// A single timestamped lyric line from an .lrc file.
struct Lyric: Identifiable, Sendable {
    let id: UUID
    let timestamp: TimeInterval  // seconds
    let text: String

    init(timestamp: TimeInterval, text: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.text = text
    }
}
