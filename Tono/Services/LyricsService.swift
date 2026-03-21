import Foundation

/// A single result from the LRCLIB search API.
struct LyricsSearchResult: Identifiable, Sendable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: TimeInterval
    let syncedLyrics: String?
    let plainLyrics: String?

    var hasSyncedLyrics: Bool {
        guard let synced = syncedLyrics else { return false }
        return !synced.isEmpty
    }
}

/// Fetches synced lyrics from the LRCLIB API and caches them locally.
final class LyricsService: Sendable {

    static let shared = LyricsService()

    private let cache = LyricsCache.shared
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Fetch and cache lyrics for a song. Returns an AsyncThrowingStream
    /// that yields progress values (0.0, 0.5, 1.0). If lyrics are already
    /// cached, or fetching fails, this completes silently without throwing.
    func fetchAndCache(
        title: String,
        artist: String,
        songID: UUID
    ) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            Task.detached(priority: .background) {
                continuation.yield(0.0)

                // Skip if already cached
                guard !self.cache.hasLyrics(for: songID) else {
                    continuation.yield(1.0)
                    continuation.finish()
                    return
                }

                continuation.yield(0.5)

                do {
                    guard let lrcContent = try await self.fetchLRC(title: title, artist: artist) else {
                        // No synced lyrics found — finish silently
                        continuation.finish()
                        return
                    }
                    try self.cache.saveLyrics(lrcContent, for: songID)
                    continuation.yield(1.0)
                    continuation.finish()
                } catch {
                    // Network or parse errors are non-fatal — finish without throwing
                    continuation.finish()
                }
            }
        }
    }

    /// Search LRCLIB for lyrics matching a free-text query. Returns an array of results.
    func search(query: String) async throws -> [LyricsSearchResult] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Tono/1.0 (macOS; contact@tono.app)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else { return [] }

        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        return jsonArray.compactMap { json -> LyricsSearchResult? in
            guard let id = json["id"] as? Int,
                  let trackName = json["trackName"] as? String,
                  let artistName = json["artistName"] as? String else { return nil }
            return LyricsSearchResult(
                id: id,
                trackName: trackName,
                artistName: artistName,
                albumName: json["albumName"] as? String ?? "",
                duration: json["duration"] as? TimeInterval ?? 0,
                syncedLyrics: json["syncedLyrics"] as? String,
                plainLyrics: json["plainLyrics"] as? String
            )
        }
    }

    // MARK: - LRCLIB API

    /// Calls LRCLIB to find synced lyrics. Returns raw .lrc string, or nil if not found.
    /// First tries an exact match via /api/get, then falls back to /api/search.
    private func fetchLRC(title: String, artist: String) async throws -> String? {
        // 1. Try exact match
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist)
        ]

        if let url = components.url {
            var request = URLRequest(url: url)
            request.setValue("Tono/1.0 (macOS; contact@tono.app)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let synced = json["syncedLyrics"] as? String, !synced.isEmpty {
                return synced
            }
        }

        // 2. Fallback: free-text search, preferring artist + title when we have both.
        let trimmedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchQueries = [
            (trimmedArtist.isEmpty ? nil : "\(trimmedArtist) \(title)"),
            title
        ].compactMap { $0 }

        for query in searchQueries {
            let results = try await search(query: query)
            if let best = results.first(where: { $0.hasSyncedLyrics }),
               let synced = best.syncedLyrics {
                return synced
            }
        }

        return nil
    }
}
