import Foundation

/// Manages loading and real-time highlighting of lyrics for the current song.
@Observable
@MainActor
final class LyricsViewModel {

    private(set) var lyrics: [Lyric] = []
    private(set) var currentIndex: Int = -1

    // MARK: - Search State
    var isSearching = false
    var searchQuery = ""
    var searchResults: [LyricsSearchResult] = []
    var isLoadingSearch = false
    var searchError: String?

    private let cache = LyricsCache.shared
    private let lyricsService = LyricsService.shared
    private var loadedSongID: UUID?
    private var searchTask: Task<Void, Never>?

    // MARK: - Loading

    /// Load lyrics for a song from the local cache.
    func loadLyrics(for songID: UUID) {
        guard loadedSongID != songID else { return }
        loadedSongID = songID
        currentIndex = -1
        lyrics = cache.loadLyrics(for: songID) ?? []
    }

    /// Force a re-read from cache for the current song (e.g. after background fetch completes).
    func reloadLyrics(for songID: UUID) {
        loadedSongID = nil
        loadLyrics(for: songID)
    }

    func clearLyrics() {
        lyrics = []
        currentIndex = -1
        loadedSongID = nil
    }

    // MARK: - Playback Sync

    /// Update the highlighted line based on current playback time.
    func update(currentTime: TimeInterval) {
        guard !lyrics.isEmpty else { return }

        // Binary-search for the last lyric whose timestamp <= currentTime
        var lo = 0
        var hi = lyrics.count - 1
        var result = -1

        while lo <= hi {
            let mid = (lo + hi) / 2
            if lyrics[mid].timestamp <= currentTime {
                result = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        if result != currentIndex {
            currentIndex = result
        }
    }

    // MARK: - Manual Search

    /// Open search UI, pre-filling query with a cleaned version of the song title.
    func beginSearch(songTitle: String, songArtist: String) {
        isSearching = true
        let cleaned = cleanSearchQuery(songTitle)
        let titleQuery = cleaned.isEmpty ? songTitle : cleaned
        let artistQuery = songArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        if artistQuery.isEmpty || artistQuery.localizedCaseInsensitiveCompare("Unknown Artist") == .orderedSame {
            searchQuery = titleQuery
        } else {
            searchQuery = "\(artistQuery) \(titleQuery)"
        }
        searchResults = []
        searchError = nil
        isLoadingSearch = false
    }

    /// Close search UI and reset state.
    func cancelSearch() {
        searchTask?.cancel()
        isSearching = false
        searchQuery = ""
        searchResults = []
        isLoadingSearch = false
        searchError = nil
    }

    /// Execute a search against LRCLIB.
    func performSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        searchTask?.cancel()
        isLoadingSearch = true
        searchError = nil
        searchResults = []

        searchTask = Task {
            do {
                let results = try await lyricsService.search(query: query)
                guard !Task.isCancelled else { return }
                searchResults = results
                isLoadingSearch = false
                if results.isEmpty {
                    searchError = "No results found"
                }
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingSearch = false
                searchError = "Search failed"
            }
        }
    }

    /// Save the chosen search result as the song's lyrics and reload the display.
    func selectResult(_ result: LyricsSearchResult, for songID: UUID) {
        // Prefer synced lyrics; fall back to plain text
        guard let lrcContent = result.syncedLyrics ?? result.plainLyrics,
              !lrcContent.isEmpty else {
            searchError = "No lyrics content available"
            return
        }

        do {
            try cache.saveLyrics(lrcContent, for: songID)
            isSearching = false
            searchQuery = ""
            searchResults = []
            loadedSongID = nil  // Force reload
            loadLyrics(for: songID)
        } catch {
            searchError = "Failed to save lyrics"
        }
    }

    // MARK: - Helpers

    /// Strip common YouTube video title noise before using as a search query.
    private func cleanSearchQuery(_ title: String) -> String {
        var cleaned = title
        let patterns = [
            #"(?i)\s*[\(\[](official\s*(music\s*)?video|lyrics?|audio|hd|hq|4k|mv|visualizer|live|edit|version|remaster(ed)?)[\)\]]"#,
            #"(?i)\s*[\(\[].*?video.*?[\)\]]"#,
            #"(?i)\s*[\(\[].*?lyrics.*?[\)\]]"#,
            #"\s*-\s*$"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: NSRange(cleaned.startIndex..., in: cleaned),
                    withTemplate: ""
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return cleaned
    }
}
