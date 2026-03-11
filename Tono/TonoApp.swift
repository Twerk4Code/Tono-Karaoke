import SwiftUI
import AppKit

@main
struct TonoApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appState)
                .environmentObject(appState.audioEngine)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 1100, height: 740)

        Settings {
            SettingsView()
                .environment(appState)
                .environmentObject(appState.audioEngine)
        }

        MenuBarExtra {
            MenuBarExtraView()
        } label: {
            Image("MenuBarIcon")
        }
    }
}
