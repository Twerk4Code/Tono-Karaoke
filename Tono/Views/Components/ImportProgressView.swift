import SwiftUI

struct ImportProgressView: View {
    let progress: Double
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 4)
                        .frame(width: 64, height: 64)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(TonoColors.cyan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 64, height: 64)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.2), value: progress)
                    Image(systemName: "waveform")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(TonoColors.cyan)
                        .scaleEffect(isPulsing ? 1.1 : 0.95)
                        .opacity(isPulsing ? 1 : 0.7)
                }

                VStack(spacing: 6) {
                    Text("Separating stems…")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white)
                    Text("\(Int(progress * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(TonoColors.textSecondary)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous)
                    .fill(TonoColors.surface)
                    .shadow(color: TonoColors.cyan.opacity(0.15), radius: 30)
                    .overlay(
                        RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
        }
        .transition(.opacity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}
