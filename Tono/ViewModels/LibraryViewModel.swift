import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AppKit

enum SortOrder: String, CaseIterable {
    case dateAdded, title, artist

    var label: String {
        switch self {
        case .dateAdded: "Recent"
        case .title: "Title"
        case .artist: "Artist"
        }
    }
}

@Observable
@MainActor
final class LibraryViewModel {

    var searchText = ""
    var sortOrder: SortOrder = .dateAdded
    var selectedFolderID: UUID?

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    var filteredSongs: [Song] {
        var songs = appState.library.songs

        // Folder filter
        if let selectedFolderID {
            songs = songs.filter { $0.folderID == selectedFolderID }
        }

        // Filter
        if !searchText.isEmpty {
            songs = songs.filter {
                $0.title.localizedCaseInsensitiveContains(searchText) ||
                $0.artist.localizedCaseInsensitiveContains(searchText)
            }
        }

        // Sort
        switch sortOrder {
        case .dateAdded:
            songs.sort { $0.dateAdded > $1.dateAdded }
        case .title:
            songs.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist:
            songs.sort { $0.artist.localizedCaseInsensitiveCompare($1.artist) == .orderedAscending }
        }

        return songs
    }

    var folders: [LibraryFolder] {
        appState.library.folders
    }

    @discardableResult
    func createFolder(named name: String) -> LibraryFolder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appState.currentError = "Folder name cannot be empty."
            return nil
        }
        guard let folder = appState.library.addFolder(named: trimmed) else {
            appState.currentError = "A folder with that name already exists."
            return nil
        }
        return folder
    }

    func moveSong(_ song: Song, to folderID: UUID?) {
        appState.library.assignSong(song.id, to: folderID)
        if appState.selectedSong?.id == song.id {
            appState.selectedSong?.folderID = folderID
        }
    }

    func revealStorageRootInFinder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: UploadFileStore.shared.tonoDirectory.path)
    }

    func revealSongFilesInFinder(_ song: Song) {
        var urls: [URL] = []
        if let upload = song.storedUploadURL, FileManager.default.fileExists(atPath: upload.path) {
            urls.append(upload)
        }
        if let vocal = song.vocalURL, FileManager.default.fileExists(atPath: vocal.path) {
            urls.append(vocal)
        }
        if let instrumental = song.instrumentalURL, FileManager.default.fileExists(atPath: instrumental.path) {
            urls.append(instrumental)
        }

        if urls.isEmpty {
            revealStorageRootInFinder()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func importFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.mp3, .wav, UTType(filenameExtension: "m4a")!]
        panel.title = "Import Songs"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        appState.beginImport(from: panel.urls)
    }

    func deleteSong(_ song: Song) {
        if appState.selectedSong?.id == song.id {
            // Stop pitch tracking and pause playback before clearing the selection.
            appState.pitchTracker.stopTracking()
            appState.audioEngine.pause()
            appState.selectedSong = nil
        }
        appState.deleteLyricsForSong(song.id)
        appState.library.deleteSong(song)
    }
}
