import SwiftUI
import AppKit

struct MenuBarExtraView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Open Tono") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            SettingsLink {
                Text("Settings…")
            }

            Divider()

            Button("Quit Tono") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(minWidth: 180)
    }
}
