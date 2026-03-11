import Foundation

/// Manages local storage of .lrc lyrics files.
/// Stored at ~/Library/Application Support/Tono/lyrics/{uuid}.lrc
final class LyricsCache: Sendable {

    static let shared = LyricsCache()

    private let lyricsDirectory: URL

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        lyricsDirectory = appSupport
            .appendingPathComponent("Tono", isDirectory: true)
            .appendingPathComponent("lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: lyricsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Public API

    /// Returns the URL where lyrics for a song would be stored.
    func lyricsURL(for songID: UUID) -> URL {
        lyricsDirectory.appendingPathComponent("\(songID.uuidString).lrc")
    }

    /// Returns true if a cached .lrc file exists for the given song.
    func hasLyrics(for songID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: lyricsURL(for: songID).path)
    }

    /// Reads and parses cached .lrc content into Lyric lines, or returns nil if not cached.
    func loadLyrics(for songID: UUID) -> [Lyric]? {
        let url = lyricsURL(for: songID)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseLRC(content)
    }

    /// Writes raw .lrc content to disk.
    func saveLyrics(_ content: String, for songID: UUID) throws {
        let url = lyricsURL(for: songID)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Deletes the cached lyrics file for a song.
    func deleteLyrics(for songID: UUID) {
        try? FileManager.default.removeItem(at: lyricsURL(for: songID))
    }

    // MARK: - LRC Parsing

    /// Parse .lrc format: [MM:SS.xx] lyric text
    func parseLRC(_ content: String) -> [Lyric] {
        var lyrics: [Lyric] = []
        let lines = content.components(separatedBy: .newlines)

        for line in lines {
            // Match [MM:SS.xx] or [MM:SS.xxx] timestamps
            guard let timestampRange = line.range(of: #"^\[(\d{2}):(\d{2})\.(\d{2,3})\]"#, options: .regularExpression) else {
                continue
            }
            let timestampStr = String(line[timestampRange])
            let text = line[timestampRange.upperBound...].trimmingCharacters(in: .whitespaces)

            // Skip lines with no text (metadata tags like [ar:], [ti:], etc.)
            guard !text.isEmpty, !timestampStr.hasPrefix("[ar:"), !timestampStr.hasPrefix("[ti:"),
                  !timestampStr.hasPrefix("[al:"), !timestampStr.hasPrefix("[by:") else { continue }

            if let seconds = parseTimestamp(from: timestampStr) {
                lyrics.append(Lyric(timestamp: seconds, text: text))
            }
        }

        return lyrics.sorted { $0.timestamp < $1.timestamp }
    }

    private func parseTimestamp(from bracket: String) -> TimeInterval? {
        // bracket is like "[02:35.40]"
        let inner = bracket.dropFirst().dropLast() // "02:35.40"
        let parts = inner.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}
