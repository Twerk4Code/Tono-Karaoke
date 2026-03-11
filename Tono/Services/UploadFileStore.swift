import Foundation

/// Manages persistent originals at /Application Support/Tono/uploads/.
final class UploadFileStore: Sendable {

    static let shared = UploadFileStore()

    let tonoDirectory: URL
    let uploadsDirectory: URL

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        tonoDirectory = appSupport.appendingPathComponent("Tono", isDirectory: true)
        uploadsDirectory = tonoDirectory.appendingPathComponent("uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)
    }

    /// Stores a copy of an imported file under a stable name keyed by song ID.
    func storeUpload(from sourceURL: URL, songID: UUID) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let destination = uploadsDirectory.appendingPathComponent("\(songID.uuidString).\(ext)")

        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }

        do {
            try fm.copyItem(at: sourceURL, to: destination)
        } catch {
            // Some provider URLs can fail copy across volumes; retry with byte copy.
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destination, options: .atomic)
        }

        return destination
    }

    func deleteUpload(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
