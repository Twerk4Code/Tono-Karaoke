import SwiftUI

struct EQSpectrumView: View {
    let analyzer: MicSpectrumAnalyzer

    // EQ band boundaries in Hz
    private static let lowMidBoundary: Float = 180
    private static let midHighBoundary: Float = 2000
    private static let minFreq: Float = 20
    private static let maxFreq: Float = 20000

    var body: some View {
        ZStack(alignment: .topLeading) {
            if analyzer.magnitudes.isEmpty || !analyzer.isEnabled {
                placeholderView
            } else {
                spectrumCanvas
                    .overlay(bandDividersOverlay)
            }
        }
        .frame(height: 100)
        .clipShape(RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous))
        .allowsHitTesting(false)
    }

    private var placeholderView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                .fill(Color.white.opacity(0.04))
            Text("Connect microphone to see spectrum")
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(TonoColors.textTertiary)
        }
    }

    private var spectrumCanvas: some View {
        Canvas { context, size in
            let mags = analyzer.magnitudes
            guard mags.count > 1 else { return }

            let path = spectrumPath(magnitudes: mags, size: size)

            // Filled gradient under curve
            var fillPath = path
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
            fillPath.closeSubpath()

            let gradient = Gradient(stops: [
                .init(color: TonoColors.cyan.opacity(0.55), location: 0),
                .init(color: TonoColors.cyan.opacity(0.18), location: 0.5),
                .init(color: TonoColors.cyan.opacity(0.0), location: 1)
            ])
            context.fill(
                fillPath,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            // Curve line
            context.stroke(
                path,
                with: .color(TonoColors.cyan.opacity(0.75)),
                lineWidth: 1.5
            )
        }
        .background(Color.white.opacity(0.04))
    }

    private var bandDividersOverlay: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height

            let lowMidX = logFreqX(Self.lowMidBoundary, width: Float(width))
            let midHighX = logFreqX(Self.midHighBoundary, width: Float(width))

            ZStack(alignment: .topLeading) {
                // Divider lines
                Path { p in
                    p.move(to: CGPoint(x: lowMidX, y: 0))
                    p.addLine(to: CGPoint(x: lowMidX, y: height))
                }
                .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                Path { p in
                    p.move(to: CGPoint(x: midHighX, y: 0))
                    p.addLine(to: CGPoint(x: midHighX, y: height))
                }
                .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // Band labels
                bandLabel("Low", x: lowMidX / 2, topPadding: 5)
                bandLabel("Mid", x: (lowMidX + midHighX) / 2, topPadding: 5)
                bandLabel("High", x: (midHighX + width) / 2, topPadding: 5)
            }
        }
    }

    private func bandLabel(_ text: String, x: CGFloat, topPadding: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .foregroundStyle(TonoColors.textTertiary)
            .position(x: x, y: topPadding + 6)
    }

    private func spectrumPath(magnitudes: [Float], size: CGSize) -> Path {
        var path = Path()
        let count = magnitudes.count
        let sampleRate: Float = 44100
        let hzPerBin = sampleRate / Float(count * 2)

        var firstPoint = true

        for i in 1..<count {
            let hz = Float(i) * hzPerBin
            guard hz >= Self.minFreq, hz <= Self.maxFreq else { continue }

            let x = CGFloat(logFreqX(hz, width: Float(size.width)))
            let magnitude = magnitudes[i]
            let y = size.height * (1.0 - CGFloat(magnitude))

            if firstPoint {
                path.move(to: CGPoint(x: x, y: y))
                firstPoint = false
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path
    }

    private func logFreqX(_ hz: Float, width: Float) -> CGFloat {
        let logMin = log10(Self.minFreq)
        let logMax = log10(Self.maxFreq)
        let logHz = log10(max(hz, Self.minFreq))
        let normalized = (logHz - logMin) / (logMax - logMin)
        return CGFloat(normalized * width)
    }
}
