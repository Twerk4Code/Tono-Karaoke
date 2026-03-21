import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @State private var currentErrorDismissTask: Task<Void, Never>?
    @State private var importErrorDismissTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            LibraryView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 360)
        } detail: {
            Group {
                if appState.selectedSong != nil {
                    PerformanceView()
                        .transition(.opacity)
                } else {
                    EmptyStateView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: appState.selectedSong?.id)
        }
        .background(Color(hex: "#050515"))
        // Gig Mode full-window overlay
        .overlay {
            if appState.isGigModeActive {
                GigModeView()
                    .environment(appState)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: appState.isGigModeActive)
        // Error toast overlay
        .overlay(alignment: .bottom) {
            if let error = appState.currentError {
                ErrorToast(message: error) {
                    appState.dismissError()
                }
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: appState.currentError)
            }
        }
        // Import error alert
        .overlay(alignment: .bottom) {
            if let importError = appState.importError {
                ErrorToast(message: importError, isImportError: true) {
                    appState.dismissImportError()
                }
                .padding(.bottom, appState.currentError != nil ? 80 : 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.spring(duration: 0.3), value: appState.importError)
            }
        }
        // Auto-dismiss errors after 6 seconds
        .onChange(of: appState.currentError) { _, newVal in
            currentErrorDismissTask?.cancel()
            guard newVal != nil else { return }
            currentErrorDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled, appState.currentError == newVal else { return }
                withAnimation { appState.currentError = nil }
            }
        }
        .onChange(of: appState.importError) { _, newVal in
            importErrorDismissTask?.cancel()
            guard newVal != nil else { return }
            importErrorDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled, appState.importError == newVal else { return }
                withAnimation { appState.importError = nil }
            }
        }
        .onDisappear {
            currentErrorDismissTask?.cancel()
            importErrorDismissTask?.cancel()
        }
    }
}

// MARK: - Error Toast

private struct ErrorToast: View {
    let message: String
    var isImportError: Bool = false
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isImportError ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(TonoColors.red)

            Text(message)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TonoColors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: TonoRadius.medium, style: .continuous)
                .fill(TonoColors.surface)
                .shadow(color: TonoColors.red.opacity(0.2), radius: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: TonoRadius.medium, style: .continuous)
                        .strokeBorder(TonoColors.red.opacity(0.3), lineWidth: 1)
                )
        )
        .frame(maxWidth: 500)
        .padding(.horizontal, 32)
    }
}

// MARK: - Empty State

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(TonoColors.cyan.opacity(0.4))
            Text("Select a song to perform")
                .font(.system(.title3, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TonoColors.background)
    }
}
