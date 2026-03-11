import Foundation

enum ImportMode: String, Codable, Sendable {
    case separated
    case raw
}

struct Song: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var artist: String
    let originalURL: URL
    var storedUploadURL: URL?
    var vocalURL: URL?
    var instrumentalURL: URL?
    let dateAdded: Date
    var albumArt: Data?
    var duration: TimeInterval?
    var importMode: ImportMode
    var lrcURL: URL?
    var folderID: UUID?

    var isProcessed: Bool {
        vocalURL != nil && instrumentalURL != nil
    }

    /// True only when the song was imported with stem separation and stems are available.
    var hasStemSeparation: Bool {
        importMode == .separated && isProcessed
    }

    /// Use the persisted upload copy when available.
    var playbackURL: URL {
        storedUploadURL ?? originalURL
    }

    init(id: UUID = UUID(), title: String, artist: String = "Unknown Artist",
         originalURL: URL, storedUploadURL: URL? = nil, vocalURL: URL? = nil, instrumentalURL: URL? = nil,
         dateAdded: Date = Date(), albumArt: Data? = nil, duration: TimeInterval? = nil,
         importMode: ImportMode = .separated, lrcURL: URL? = nil, folderID: UUID? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.originalURL = originalURL
        self.storedUploadURL = storedUploadURL
        self.vocalURL = vocalURL
        self.instrumentalURL = instrumentalURL
        self.dateAdded = dateAdded
        self.albumArt = albumArt
        self.duration = duration
        self.importMode = importMode
        self.lrcURL = lrcURL
        self.folderID = folderID
    }

    // MARK: - Codable (backward-compatible: missing importMode defaults to .separated)

    enum CodingKeys: String, CodingKey {
        case id, title, artist, originalURL, storedUploadURL, vocalURL, instrumentalURL
        case dateAdded, albumArt, duration, importMode, lrcURL, folderID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decode(UUID.self,          forKey: .id)
        title          = try c.decode(String.self,        forKey: .title)
        artist         = try c.decode(String.self,        forKey: .artist)
        originalURL    = try c.decode(URL.self,           forKey: .originalURL)
        storedUploadURL = try c.decodeIfPresent(URL.self, forKey: .storedUploadURL)
        vocalURL       = try c.decodeIfPresent(URL.self,  forKey: .vocalURL)
        instrumentalURL = try c.decodeIfPresent(URL.self, forKey: .instrumentalURL)
        dateAdded      = try c.decode(Date.self,          forKey: .dateAdded)
        albumArt       = try c.decodeIfPresent(Data.self, forKey: .albumArt)
        duration       = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        importMode     = try c.decodeIfPresent(ImportMode.self,   forKey: .importMode) ?? .separated
        lrcURL         = try c.decodeIfPresent(URL.self,  forKey: .lrcURL)
        folderID       = try c.decodeIfPresent(UUID.self, forKey: .folderID)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,            forKey: .id)
        try c.encode(title,         forKey: .title)
        try c.encode(artist,        forKey: .artist)
        try c.encode(originalURL,   forKey: .originalURL)
        try c.encodeIfPresent(storedUploadURL, forKey: .storedUploadURL)
        try c.encodeIfPresent(vocalURL,          forKey: .vocalURL)
        try c.encodeIfPresent(instrumentalURL,   forKey: .instrumentalURL)
        try c.encode(dateAdded,     forKey: .dateAdded)
        try c.encodeIfPresent(albumArt,  forKey: .albumArt)
        try c.encodeIfPresent(duration,  forKey: .duration)
        try c.encode(importMode,    forKey: .importMode)
        try c.encodeIfPresent(lrcURL,    forKey: .lrcURL)
        try c.encodeIfPresent(folderID,  forKey: .folderID)
    }
}
