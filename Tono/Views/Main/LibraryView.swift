import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: LibraryViewModel?
    @State private var isDragTargeted = false
    @State private var showingCreateFolderAlert = false
    @State private var newFolderName = ""

    var body: some View {
        VStack(spacing: 0) {
            if let vm = viewModel {
                libraryContent(vm: vm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TonoColors.surface)
        // Import progress overlay
        .overlay {
            if appState.isImporting {
                ImportProgressView(progress: appState.importProgress)
            }
        }
        // Drag & drop import — on the outer VStack so it always accepts drops
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
        // Import mode choice dialog
        .confirmationDialog(
            "How would you like to import?",
            isPresented: Binding(
                get: { appState.showImportChoiceDialog },
                set: { if !$0 { appState.showImportChoiceDialog = false } }
            ),
            titleVisibility: .visible
        ) {
            Button("Separate Stems") {
                appState.importWithStemSeparation()
            }
            Button("Raw Upload") {
                appState.importRaw()
            }
            Button("Cancel", role: .cancel) {
                appState.showImportChoiceDialog = false
                appState.pendingImportURLs = nil
            }
        } message: {
            Text("\"Separate Stems\" runs AI vocal separation (slower). \"Raw Upload\" adds the file instantly with no separation.")
        }
        .alert("Create Folder", isPresented: $showingCreateFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                let created = viewModel?.createFolder(named: newFolderName)
                if let created {
                    viewModel?.selectedFolderID = created.id
                }
                newFolderName = ""
            }
            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {
                newFolderName = ""
            }
        } message: {
            Text("Create folders to organize songs in your library.")
        }
        .task {
            if viewModel == nil {
                viewModel = LibraryViewModel(appState: appState)
            }
        }
    }

    // MARK: - Drop Handler

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let audioExtensions: Set<String> = ["mp3", "wav", "m4a"]
        let audioProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !audioProviders.isEmpty else { return false }

        Task {
            var collectedURLs: [URL] = []
            for provider in audioProviders {
                guard let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
                collectedURLs.append(url)
            }
            guard !collectedURLs.isEmpty else { return }
            await MainActor.run { appState.beginImport(from: collectedURLs) }
        }
        return true
    }

    // MARK: - Library Content

    @ViewBuilder
    private func libraryContent(vm: LibraryViewModel) -> some View {
        // Header
        HStack {
            Text("Library")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            Button {
                vm.revealStorageRootInFinder()
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TonoColors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Open storage folders in Finder")

            Button {
                showingCreateFolderAlert = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(TonoColors.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Create folder")

            Button {
                vm.importFromPanel()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(TonoColors.cyan)
            }
            .buttonStyle(.plain)
            .help("Import song")
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 12)

        // Search
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(TonoColors.textSecondary)
            TextField("Search songs...", text: Binding(
                get: { vm.searchText },
                set: { vm.searchText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(.subheadline, design: .rounded))
            .foregroundStyle(.white)

            if !vm.searchText.isEmpty {
                Button {
                    vm.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(TonoColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                .fill(Color.white.opacity(0.06))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 4)

        if !vm.folders.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    folderFilterChip(title: "All Songs", isSelected: vm.selectedFolderID == nil) {
                        vm.selectedFolderID = nil
                    }

                    ForEach(vm.folders) { folder in
                        folderFilterChip(title: folder.name, isSelected: vm.selectedFolderID == folder.id) {
                            vm.selectedFolderID = folder.id
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.bottom, 8)
        }

        // Sort control
        HStack {
            Spacer()
            Menu {
                Button { vm.sortOrder = .dateAdded } label: {
                    Label("Date Added", systemImage: vm.sortOrder == .dateAdded ? "checkmark" : "")
                }
                Button { vm.sortOrder = .title } label: {
                    Label("Title", systemImage: vm.sortOrder == .title ? "checkmark" : "")
                }
                Button { vm.sortOrder = .artist } label: {
                    Label("Artist", systemImage: vm.sortOrder == .artist ? "checkmark" : "")
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 10))
                    Text(vm.sortOrder.label)
                        .font(.system(.caption2, design: .rounded))
                }
                .foregroundStyle(TonoColors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)

        Divider().opacity(0.15)

        // Song count
        if !vm.filteredSongs.isEmpty {
            HStack {
                Text("\(vm.filteredSongs.count) song\(vm.filteredSongs.count == 1 ? "" : "s")")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(TonoColors.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }

        // Song List or Empty State
        if vm.filteredSongs.isEmpty {
            Spacer()
            if vm.searchText.isEmpty {
                if vm.selectedFolderID == nil {
                    importDropZone(vm: vm)
                        .padding(.horizontal, 16)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(TonoColors.textTertiary)
                        Text("No songs in this folder")
                            .font(.system(.callout, design: .rounded))
                            .foregroundStyle(TonoColors.textTertiary)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .thin))
                        .foregroundStyle(TonoColors.textTertiary)
                    Text("No results for \"\(vm.searchText)\"")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(TonoColors.textTertiary)
                }
            }
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(vm.filteredSongs) { song in
                        SongCard(
                            song: song,
                            isSelected: appState.selectedSong?.id == song.id,
                            onRevealFiles: {
                                vm.revealSongFilesInFinder(song)
                            },
                            onDelete: {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    vm.deleteSong(song)
                                }
                            }
                        )
                        .onTapGesture {
                            appState.selectSong(song)
                        }
                        .contextMenu {
                            Menu("Move to Folder") {
                                Button {
                                    vm.moveSong(song, to: nil)
                                } label: {
                                    Label("No Folder", systemImage: song.folderID == nil ? "checkmark" : "")
                                }

                                if vm.folders.isEmpty {
                                    Button("Create a folder first") {}
                                        .disabled(true)
                                } else {
                                    ForEach(vm.folders) { folder in
                                        Button {
                                            vm.moveSong(song, to: folder.id)
                                        } label: {
                                            Label(folder.name, systemImage: song.folderID == folder.id ? "checkmark" : "")
                                        }
                                    }
                                }
                            }
                            Button {
                                vm.revealSongFilesInFinder(song)
                            } label: {
                                Label("Show Stored Files in Finder", systemImage: "folder")
                            }
                            Button(role: .destructive) {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    vm.deleteSong(song)
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .slide),
                            removal: .opacity.combined(with: .move(edge: .leading))
                        ))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
                .animation(.easeInOut(duration: 0.25), value: vm.filteredSongs.map(\.id))
            }
        }
    }

    // MARK: - Import Drop Zone

    @ViewBuilder
    private func importDropZone(vm: LibraryViewModel) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isDragTargeted ? TonoColors.cyan : TonoColors.textTertiary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isDragTargeted ? TonoColors.cyan.opacity(0.07) : Color.clear)

            VStack(spacing: 14) {
                Image(systemName: isDragTargeted ? "arrow.down.circle.fill" : "music.note.list")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(isDragTargeted ? TonoColors.cyan : TonoColors.textTertiary)

                VStack(spacing: 4) {
                    Text(isDragTargeted ? "Release to import" : "Drop songs here")
                        .font(.system(.callout, design: .rounded, weight: .medium))
                        .foregroundStyle(isDragTargeted ? TonoColors.cyan : TonoColors.textSecondary)
                    if !isDragTargeted {
                        Text("MP3, WAV, M4A")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(TonoColors.textTertiary)
                    }
                }

                if !isDragTargeted {
                    Button {
                        vm.importFromPanel()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 13, weight: .medium))
                            Text("Import from Folder")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        }
                        .foregroundStyle(TonoColors.cyan)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(TonoColors.cyan.opacity(0.13))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(32)
        }
        .animation(.easeInOut(duration: 0.15), value: isDragTargeted)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func folderFilterChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : TonoColors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? TonoColors.cyan.opacity(0.25) : Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? TonoColors.cyan.opacity(0.45) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
