import SwiftUI

enum TonoColors {
    static let background  = Color(hex: "#050515")
    static let surface     = Color(hex: "#0F0F1E")
    static let cyan        = Color(hex: "#00D9FF")   // vocals
    static let purple      = Color(hex: "#9D00FF")   // instrumental
    static let green       = Color(hex: "#00FF88")   // on pitch
    static let red         = Color(hex: "#FF3366")   // off pitch
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.6)
    static let textTertiary  = Color.white.opacity(0.3)
}

enum TonoRadius {
    static let small:  CGFloat = 10
    static let medium: CGFloat = 14
    static let large:  CGFloat = 20
}

enum TonoGlass {
    /// Standard glass card background
    static var surface: some View {
        ZStack {
            Color.white.opacity(0.06)
            LinearGradient(
                colors: [Color.white.opacity(0.04), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}
