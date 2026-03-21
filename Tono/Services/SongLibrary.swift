import Foundation

/// Persistent JSON-backed song index.
/// Stored at /Application Support/Tono/library.json
@Observable
final class SongLibrary: @unchecked Sendable {

    private(set) var songs: [Song] = []
    private(set) var folders: [LibraryFolder] = []
    private let storageURL: URL
    private static let persistenceKey = "com.tono.library"
    private static let saveDebounceSeconds: TimeInterval = 0.4
    private var pendingSaveWorkItem: DispatchWorkItem?

    init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let tonoDir = appSupport.appendingPathComponent("Tono", isDirectory: true)
        try? FileManager.default.createDirectory(at: tonoDir, withIntermediateDirectories: true)
        storageURL = tonoDir.appendingPathComponent("library.json")
        load()
    }

    deinit {
        pendingSaveWorkItem?.cancel()
    }

    // MARK: - CRUD

    func addSong(_ song: Song) {
        songs.append(song)
        save()
    }

    func updateSong(_ song: Song) {
        guard let idx = songs.firstIndex(where: { $0.id == song.id }) else { return }
        songs[idx] = song
        save()
    }

    func deleteSong(_ song: Song) {
        songs.removeAll { $0.id == song.id }
        StemFileStore.shared.deleteStems(for: song.id)
        UploadFileStore.shared.deleteUpload(at: song.storedUploadURL)
        save()
    }

    func song(for id: UUID) -> Song? {
        songs.first { $0.id == id }
    }

    func assignSong(_ songID: UUID, to folderID: UUID?) {
        guard let idx = songs.firstIndex(where: { $0.id == songID }) else { return }
        if let folderID, folders.contains(where: { $0.id == folderID }) == false {
            return
        }
        songs[idx].folderID = folderID
        save()
    }

    @discardableResult
    func addFolder(named name: String) -> LibraryFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard folders.contains(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) == false else {
            return nil
        }

        let folder = LibraryFolder(name: trimmed)
        folders.append(folder)
        folders.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save()
        return folder
    }

    func folder(for id: UUID) -> LibraryFolder? {
        folders.first { $0.id == id }
    }

    func deleteFolder(_ folderID: UUID) {
        folders.removeAll { $0.id == folderID }
        for index in songs.indices where songs[index].folderID == folderID {
            songs[index].folderID = nil
        }
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        FileWriteDeduper.shared.seedLastWrittenData(data, forKey: Self.persistenceKey)
        let decoder = JSONDecoder()

        if let decoded = try? decoder.decode(StoragePayload.self, from: data) {
            songs = decoded.songs
            folders = decoded.folders
            sanitizeFolderAssignments()
            return
        }

        // Backward compatibility for old `library.json` layout ([Song]).
        if let decodedSongs = try? decoder.decode([Song].self, from: data) {
            songs = decodedSongs
            folders = []
        }
    }

    private func save() {
        pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistSnapshot()
        }
        pendingSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDebounceSeconds, execute: workItem)
    }

    private func persistSnapshot() {
        let payload = StoragePayload(songs: songs, folders: folders)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        FileWriteDeduper.shared.writeIfChanged(
            data,
            to: storageURL,
            key: Self.persistenceKey
        )
    }

    private func sanitizeFolderAssignments() {
        let validIDs = Set(folders.map(\.id))
        for index in songs.indices {
            if let folderID = songs[index].folderID, !validIDs.contains(folderID) {
                songs[index].folderID = nil
            }
        }
    }
}

private struct StoragePayload: Codable {
    let songs: [Song]
    let folders: [LibraryFolder]
}
