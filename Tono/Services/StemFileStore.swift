import Foundation

/// Manages the /Application Support/Tono/stems/ directory for persistent stem storage.
final class StemFileStore: Sendable {

    static let shared = StemFileStore()

    let stemsDirectory: URL

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        stemsDirectory = appSupport.appendingPathComponent("Tono/stems", isDirectory: true)
        try? FileManager.default.createDirectory(at: stemsDirectory, withIntermediateDirectories: true)
    }

    /// Returns true if stems already exist for this song (skip re-processing).
    func stemsExist(for songID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: vocalURL(for: songID).path) &&
        FileManager.default.fileExists(atPath: instrumentalURL(for: songID).path)
    }

    func vocalURL(for songID: UUID) -> URL {
        stemsDirectory.appendingPathComponent("\(songID.uuidString)_vocals.wav")
    }

    func instrumentalURL(for songID: UUID) -> URL {
        stemsDirectory.appendingPathComponent("\(songID.uuidString)_instrumental.wav")
    }

    /// Remove stems for a specific song (e.g., when deleting from library).
    func deleteStems(for songID: UUID) {
        try? FileManager.default.removeItem(at: vocalURL(for: songID))
        try? FileManager.default.removeItem(at: instrumentalURL(for: songID))
    }
}
