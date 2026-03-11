import AVFoundation
import Accelerate
import Foundation
import QuartzCore

@Observable
final class PlaybackVisualizerAnalyzer: @unchecked Sendable {
    private(set) var features: PlaybackVisualizerFeatures = .zero
    private(set) var isEnabled = false

    private var intensity: Float = 0.45

    private let stateLock = NSLock()
    private let analysisQueue = DispatchQueue(label: "com.tono.visualizer.analysis", qos: .userInitiated)
    private let analysisGate = DispatchSemaphore(value: 1)
    private let publishInterval: CFTimeInterval = 1.0 / 120.0

    private var realtimeEnabled = false
    private var realtimeIntensity: Float = 0.45
    private var lastSubmissionTime: CFTimeInterval = 0
    private var realtimeFeatures: PlaybackVisualizerFeatures = .zero
    private var realtimeFeaturesTimestamp: CFTimeInterval = 0

    private let nFFT: Int
    private let log2n: vDSP_Length
    private let halfN: Int
    private let window: [Float]
    private let fftSetup: FFTSetup?

    private var previousSpectrum: [Float]
    private var smoothedBands = SIMD3<Float>(repeating: 0)
    private var smoothedOverall: Float = 0
    private var smoothedFlux: Float = 0
    private var beatEnvelope: Float = 0
    private var previousBassForBeat: Float = 0
#if DEBUG
    private var debugFrameCount: Int = 0
    private var debugLastLogTime: CFTimeInterval = 0
#endif

    init(nFFT: Int = 1024) {
        self.nFFT = nFFT
        self.halfN = nFFT / 2
        let l2 = vDSP_Length(log2(Double(nFFT)))
        self.log2n = l2

        var generatedWindow = [Float](repeating: 0, count: nFFT)
        vDSP_hann_window(&generatedWindow, vDSP_Length(nFFT), Int32(vDSP_HANN_NORM))
        self.window = generatedWindow

        self.fftSetup = vDSP_create_fftsetup(l2, FFTRadix(kFFTRadix2))
        if fftSetup == nil {
            print("[PlaybackVisualizerAnalyzer] FFT setup unavailable for n=\(nFFT); visualizer analysis will remain idle")
        }
        self.previousSpectrum = [Float](repeating: 0, count: halfN + 1)
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled

        stateLock.lock()
        realtimeEnabled = enabled
        if enabled {
            lastSubmissionTime = 0
            realtimeFeaturesTimestamp = 0
        }
        stateLock.unlock()
#if DEBUG
        if enabled {
            debugFrameCount = 0
            debugLastLogTime = 0
            print("[Visualizer][Analyzer] Enabled")
        } else {
            print("[Visualizer][Analyzer] Disabled")
        }
#endif

        if !enabled {
            reset()
        }
    }

    func setIntensity(_ value: Float) {
        let clamped = max(0.15, min(0.8, value))
        intensity = clamped

        stateLock.lock()
        realtimeIntensity = clamped
        stateLock.unlock()
    }

    func reset() {
        features = .zero

        stateLock.lock()
        realtimeFeatures = .zero
        realtimeFeaturesTimestamp = 0
        stateLock.unlock()

        analysisQueue.async { [weak self] in
            guard let self else { return }
            self.previousSpectrum = [Float](repeating: 0, count: self.halfN + 1)
            self.smoothedBands = SIMD3<Float>(repeating: 0)
            self.smoothedOverall = 0
            self.smoothedFlux = 0
            self.beatEnvelope = 0
            self.previousBassForBeat = 0
        }
    }

    func latestFeaturesSnapshot() -> PlaybackVisualizerFeatures {
        let now = CACurrentMediaTime()
        stateLock.lock()
        let snapshot = realtimeFeatures
        let timestamp = realtimeFeaturesTimestamp
        stateLock.unlock()

        guard timestamp > 0 else { return .zero }
        let age = max(0, now - timestamp)
        guard age > 0.12 else { return snapshot }

        let fadeDuration: Float = 0.60
        let fade = max(0, 1 - Float(age - 0.12) / fadeDuration)
        return decayedSnapshot(snapshot, factor: fade)
    }

    func consumeAudioBuffer(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) {
        let now = CACurrentMediaTime()
        var enabled = false
        var currentIntensity: Float = 0.45
        var shouldSubmit = false

        stateLock.lock()
        enabled = realtimeEnabled
        currentIntensity = realtimeIntensity
        if enabled && now - lastSubmissionTime >= publishInterval {
            lastSubmissionTime = now
            shouldSubmit = true
        }
        stateLock.unlock()

        guard shouldSubmit else { return }
        guard analysisGate.wait(timeout: .now()) == .success else { return }
        guard let monoSamples = extractMonoSamples(from: buffer) else {
            analysisGate.signal()
            return
        }

        let stereoWidth = extractStereoWidth(from: buffer)
        let sampleRate = Float(buffer.format.sampleRate)
        let capturedIntensity = currentIntensity

        analysisQueue.async { [weak self] in
            guard let self else { return }
            defer { self.analysisGate.signal() }

            let next = self.analyze(
                monoSamples: monoSamples,
                sampleRate: sampleRate,
                stereoWidth: stereoWidth,
                intensity: capturedIntensity
            )

            let publishTime = CACurrentMediaTime()
            self.stateLock.lock()
            let stillEnabled = self.realtimeEnabled
            if stillEnabled {
                self.realtimeFeatures = next
                self.realtimeFeaturesTimestamp = publishTime
            }
            self.stateLock.unlock()
            guard stillEnabled else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let enabledOnMain = self.realtimeEnabled
                self.stateLock.unlock()
                guard enabledOnMain else { return }
                self.features = next
#if DEBUG
                self.debugLogCadence(features: next)
#endif
            }
        }
    }

    private func analyze(
        monoSamples: [Float],
        sampleRate: Float,
        stereoWidth: Float,
        intensity: Float
    ) -> PlaybackVisualizerFeatures {
        guard let fftSetup else {
            return PlaybackVisualizerFeatures(
                overallEnergy: 0,
                bassEnergy: 0,
                midEnergy: 0,
                trebleEnergy: 0,
                beatImpulse: 0,
                spectralFlux: 0,
                stereoWidth: clamp01(stereoWidth),
                isSilent: true
            )
        }

        var frame = [Float](repeating: 0, count: nFFT)
        if monoSamples.count >= nFFT {
            let start = monoSamples.count - nFFT
            for i in 0..<nFFT {
                frame[i] = monoSamples[start + i]
            }
        } else {
            let start = nFFT - monoSamples.count
            for i in 0..<monoSamples.count {
                frame[start + i] = monoSamples[i]
            }
        }

        var windowed = [Float](repeating: 0, count: nFFT)
        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(nFFT))

        var splitReal = [Float](repeating: 0, count: halfN)
        var splitImag = [Float](repeating: 0, count: halfN)

        for i in 0..<halfN {
            splitReal[i] = windowed[2 * i]
            splitImag[i] = windowed[2 * i + 1]
        }

        splitReal.withUnsafeMutableBufferPointer { realBuf in
            splitImag.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        var spectrum = [Float](repeating: 0, count: halfN + 1)
        let scale = 1.0 / Float(nFFT)
        spectrum[0] = abs(splitReal[0]) * scale
        for k in 1..<halfN {
            spectrum[k] = hypotf(splitReal[k], splitImag[k]) * scale
        }
        spectrum[halfN] = abs(splitImag[0]) * scale

        let bandEnergy = computeBandEnergy(spectrum: spectrum, sampleRate: sampleRate)
        let bass = bandEnergy.bass
        let mid = bandEnergy.mid
        let treble = bandEnergy.treble
        let overall = bandEnergy.overall

        var rawFlux: Float = 0
        for i in 0..<spectrum.count {
            let diff = spectrum[i] - previousSpectrum[i]
            if diff > 0 {
                rawFlux += diff
            }
            previousSpectrum[i] = spectrum[i]
        }
        rawFlux /= Float(spectrum.count)

        let bassNorm = compress(bass, gain: 80)
        let midNorm = compress(mid, gain: 60)
        let trebleNorm = compress(treble, gain: 40)
        let overallNorm = compress(overall, gain: 48)
        let fluxNorm = compress(rawFlux, gain: 160)

        smoothedBands.x = smooth(current: smoothedBands.x, target: bassNorm, attack: 0.34, release: 0.10)
        smoothedBands.y = smooth(current: smoothedBands.y, target: midNorm, attack: 0.32, release: 0.10)
        smoothedBands.z = smooth(current: smoothedBands.z, target: trebleNorm, attack: 0.30, release: 0.11)
        smoothedOverall = smooth(current: smoothedOverall, target: overallNorm, attack: 0.30, release: 0.09)
        smoothedFlux = smooth(current: smoothedFlux, target: fluxNorm, attack: 0.36, release: 0.14)

        let beatBaseline = smooth(current: previousBassForBeat, target: smoothedBands.x, attack: 0.12, release: 0.04)
        previousBassForBeat = beatBaseline
        let bassTransient = max(0, bassNorm - smoothedBands.x)
        let beatCandidate =
            max(0, smoothedBands.x - beatBaseline) * 1.8 +
            bassTransient * 0.95 +
            smoothedFlux * 0.28
        beatEnvelope = smooth(current: beatEnvelope, target: min(1, beatCandidate), attack: 0.42, release: 0.20)

        let intensityGain = 0.75 + intensity * 1.15
        let overallOut = clamp01(smoothedOverall * intensityGain)
        let bassOut = clamp01(smoothedBands.x * intensityGain)
        let midOut = clamp01(smoothedBands.y * intensityGain)
        let trebleOut = clamp01(smoothedBands.z * intensityGain)
        let fluxOut = clamp01(smoothedFlux * (0.7 + intensity * 0.8))
        let beatOut = clamp01(beatEnvelope * (0.9 + intensity * 0.6))
        let silent = overallOut < 0.03 && beatOut < 0.06

        return PlaybackVisualizerFeatures(
            overallEnergy: overallOut,
            bassEnergy: bassOut,
            midEnergy: midOut,
            trebleEnergy: trebleOut,
            beatImpulse: beatOut,
            spectralFlux: fluxOut,
            stereoWidth: clamp01(stereoWidth),
            isSilent: silent
        )
    }

    private func computeBandEnergy(
        spectrum: [Float],
        sampleRate: Float
    ) -> (bass: Float, mid: Float, treble: Float, overall: Float) {
        let hzPerBin = sampleRate / Float(nFFT)
        var bass: Float = 0
        var mid: Float = 0
        var treble: Float = 0
        var overall: Float = 0
        var bassCount: Float = 0
        var midCount: Float = 0
        var trebleCount: Float = 0
        var overallCount: Float = 0

        for i in 0..<spectrum.count {
            let hz = Float(i) * hzPerBin
            guard hz >= 20, hz <= 10_000 else { continue }
            let mag = spectrum[i]
            overall += mag
            overallCount += 1

            switch hz {
            case ..<180:
                bass += mag
                bassCount += 1
            case ..<2_000:
                mid += mag
                midCount += 1
            default:
                treble += mag
                trebleCount += 1
            }
        }

        return (
            bass: bassCount > 0 ? bass / bassCount : 0,
            mid: midCount > 0 ? mid / midCount : 0,
            treble: trebleCount > 0 ? treble / trebleCount : 0,
            overall: overallCount > 0 ? overall / overallCount : 0
        )
    }

    private func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { return nil }
        var mono = [Float](repeating: 0, count: frameCount)

        if channels == 1 {
            let ch = channelData[0]
            for i in 0..<frameCount {
                mono[i] = ch[i]
            }
            return mono
        }

        let inverseChannelCount = 1.0 / Float(channels)
        for channelIndex in 0..<channels {
            let ch = channelData[channelIndex]
            for i in 0..<frameCount {
                mono[i] += ch[i]
            }
        }
        for i in 0..<frameCount {
            mono[i] *= inverseChannelCount
        }
        return mono
    }

    private func extractStereoWidth(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData,
              buffer.format.channelCount >= 2 else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        let left = channelData[0]
        let right = channelData[1]

        var midEnergy: Float = 0
        var sideEnergy: Float = 0

        for i in 0..<frameCount {
            let mid = 0.5 * (left[i] + right[i])
            let side = 0.5 * (left[i] - right[i])
            midEnergy += mid * mid
            sideEnergy += side * side
        }

        guard midEnergy > 1e-7 else { return 0 }
        let width = sqrtf(sideEnergy / midEnergy)
        return clamp01(width)
    }

    private func smooth(current: Float, target: Float, attack: Float, release: Float) -> Float {
        let coeff = target > current ? attack : release
        return current + (target - current) * coeff
    }

    private func compress(_ value: Float, gain: Float) -> Float {
        guard value > 0 else { return 0 }
        let numerator = log10f(1 + value * gain)
        let denominator = log10f(1 + gain)
        guard denominator > 0 else { return 0 }
        return clamp01(numerator / denominator)
    }

    private func clamp01(_ value: Float) -> Float {
        max(0, min(1, value))
    }

    private func decayedSnapshot(_ snapshot: PlaybackVisualizerFeatures, factor: Float) -> PlaybackVisualizerFeatures {
        let f = clamp01(factor)
        let decayed = PlaybackVisualizerFeatures(
            overallEnergy: snapshot.overallEnergy * f,
            bassEnergy: snapshot.bassEnergy * f,
            midEnergy: snapshot.midEnergy * f,
            trebleEnergy: snapshot.trebleEnergy * f,
            beatImpulse: snapshot.beatImpulse * f,
            spectralFlux: snapshot.spectralFlux * f,
            stereoWidth: snapshot.stereoWidth * f,
            isSilent: f < 0.02 || snapshot.isSilent
        )
        return decayed
    }

#if DEBUG
    private func debugLogCadence(features: PlaybackVisualizerFeatures) {
        let now = CACurrentMediaTime()
        debugFrameCount += 1
        if debugLastLogTime == 0 {
            debugLastLogTime = now
            debugFrameCount = 0
            return
        }
        let elapsed = now - debugLastLogTime
        guard elapsed >= 1.5 else { return }
        let rate = Double(debugFrameCount) / max(elapsed, 0.001)
        print(
            String(
                format: "[Visualizer][Analyzer] rate=%.1fHz energy=%.3f bass=%.3f flux=%.3f beat=%.3f",
                rate,
                features.overallEnergy,
                features.bassEnergy,
                features.spectralFlux,
                features.beatImpulse
            )
        )
        debugLastLogTime = now
        debugFrameCount = 0
    }
#endif
}
