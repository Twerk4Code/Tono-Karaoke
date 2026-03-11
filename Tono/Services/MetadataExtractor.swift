import AVFoundation

/// Extracts ID3 metadata (title, artist, album art) from audio files using AVAsset.
enum MetadataExtractor {

    struct SongMetadata: Sendable {
        var title: String?
        var artist: String?
        var albumArt: Data?
        var duration: TimeInterval?
    }

    /// Extract metadata from an audio file URL.
    static func extract(from url: URL) async -> SongMetadata {
        let asset = AVURLAsset(url: url)
        var meta = SongMetadata()

        // Duration
        if let duration = try? await asset.load(.duration) {
            meta.duration = duration.seconds.isFinite ? duration.seconds : nil
        }

        // Common metadata (works for ID3, iTunes, etc.)
        guard let items = try? await asset.load(.commonMetadata) else {
            return meta
        }

        for item in items {
            guard let key = item.commonKey else { continue }
            switch key {
            case .commonKeyTitle:
                meta.title = try? await item.load(.stringValue)
            case .commonKeyArtist:
                meta.artist = try? await item.load(.stringValue)
            case .commonKeyArtwork:
                meta.albumArt = try? await item.load(.dataValue)
            default:
                break
            }
        }

        return meta
    }
}
