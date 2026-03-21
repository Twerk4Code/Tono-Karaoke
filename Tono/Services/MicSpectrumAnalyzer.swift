import AVFoundation
import Accelerate
import Foundation
import QuartzCore

@Observable
final class MicSpectrumAnalyzer: @unchecked Sendable {
    private(set) var magnitudes: [Float] = []

    var isEnabled: Bool = true

    private let nFFT: Int = 1024
    private let halfN: Int
    private let log2n: vDSP_Length
    private let window: [Float]
    private let fftSetup: FFTSetup?

    private let stateLock = NSLock()
    private let analysisQueue = DispatchQueue(label: "com.tono.micspectrum.analysis", qos: .userInitiated)
    private let analysisGate = DispatchSemaphore(value: 1)
    private let publishInterval: CFTimeInterval = 1.0 / 60.0
    private let publishEpsilon: Float = 0.0020
    private var lastSubmissionTime: CFTimeInterval = 0
    private var frameScratch: [Float]
    private var windowedScratch: [Float]
    private var splitRealScratch: [Float]
    private var splitImagScratch: [Float]
    private var magnitudesScratch: [Float]
    private var normalizedScratch: [Float]

    private static let minDB: Float = -80
    private static let maxDB: Float = 0

    init() {
        halfN = nFFT / 2
        let l2 = vDSP_Length(log2(Double(nFFT)))
        log2n = l2

        var generatedWindow = [Float](repeating: 0, count: nFFT)
        vDSP_hann_window(&generatedWindow, vDSP_Length(nFFT), Int32(vDSP_HANN_NORM))
        window = generatedWindow

        fftSetup = vDSP_create_fftsetup(l2, FFTRadix(kFFTRadix2))
        frameScratch = [Float](repeating: 0, count: nFFT)
        windowedScratch = [Float](repeating: 0, count: nFFT)
        splitRealScratch = [Float](repeating: 0, count: halfN)
        splitImagScratch = [Float](repeating: 0, count: halfN)
        magnitudesScratch = [Float](repeating: Self.minDB, count: halfN)
        normalizedScratch = [Float](repeating: 0, count: halfN)
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func processSampleBuffer(_ buffer: AVAudioPCMBuffer) {
        let now = CACurrentMediaTime()
        var enabled = false
        var shouldSubmit = false
        stateLock.lock()
        enabled = isEnabled
        if enabled, now - lastSubmissionTime >= publishInterval {
            lastSubmissionTime = now
            shouldSubmit = true
        }
        stateLock.unlock()

        guard enabled else {
            DispatchQueue.main.async { [weak self] in
                self?.magnitudes = []
            }
            return
        }
        guard shouldSubmit else { return }

        guard analysisGate.wait(timeout: .now()) == .success else { return }
        guard let monoSamples = extractMono(from: buffer) else {
            analysisGate.signal()
            return
        }

        analysisQueue.async { [weak self] in
            guard let self else { return }
            defer { self.analysisGate.signal() }

            let result = self.computeMagnitudes(monoSamples: monoSamples)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.stateLock.lock()
                let stillEnabled = self.isEnabled
                self.stateLock.unlock()
                guard stillEnabled else {
                    self.magnitudes = []
                    return
                }
                guard self.hasMeaningfulDelta(from: self.magnitudes, to: result) else { return }
                self.magnitudes = result
            }
        }
    }

    private func computeMagnitudes(monoSamples: [Float]) -> [Float] {
        guard let fftSetup else { return [] }

        vDSP_vclr(&frameScratch, 1, vDSP_Length(nFFT))
        if monoSamples.count >= nFFT {
            let start = monoSamples.count - nFFT
            for i in 0..<nFFT { frameScratch[i] = monoSamples[start + i] }
        } else {
            let start = nFFT - monoSamples.count
            for i in 0..<monoSamples.count { frameScratch[start + i] = monoSamples[i] }
        }

        vDSP_vmul(frameScratch, 1, window, 1, &windowedScratch, 1, vDSP_Length(nFFT))
        for i in 0..<halfN {
            splitRealScratch[i] = windowedScratch[2 * i]
            splitImagScratch[i] = windowedScratch[2 * i + 1]
        }

        splitRealScratch.withUnsafeMutableBufferPointer { realBuf in
            splitImagScratch.withUnsafeMutableBufferPointer { imagBuf in
                var split = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }

        let scale = 1.0 / Float(nFFT)
        magnitudesScratch[0] = 20 * log10f(max(abs(splitRealScratch[0]) * scale, 1e-10))
        for k in 1..<halfN {
            let mag = hypotf(splitRealScratch[k], splitImagScratch[k]) * scale
            magnitudesScratch[k] = 20 * log10f(max(mag, 1e-10))
        }

        let range = Self.maxDB - Self.minDB
        for index in 0..<halfN {
            let clamped = max(Self.minDB, min(Self.maxDB, magnitudesScratch[index]))
            normalizedScratch[index] = (clamped - Self.minDB) / range
        }

        // Zero out DC bin
        if !normalizedScratch.isEmpty {
            normalizedScratch[0] = 0
        }

        return normalizedScratch
    }

    private func extractMono(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }
        let channels = Int(buffer.format.channelCount)
        guard channels > 0 else { return nil }

        var mono = [Float](repeating: 0, count: frameCount)
        if channels == 1 {
            let ch = channelData[0]
            for i in 0..<frameCount { mono[i] = ch[i] }
        } else {
            let inv = 1.0 / Float(channels)
            for c in 0..<channels {
                let ch = channelData[c]
                for i in 0..<frameCount { mono[i] += ch[i] }
            }
            for i in 0..<frameCount { mono[i] *= inv }
        }
        return mono
    }

    private func hasMeaningfulDelta(from current: [Float], to next: [Float]) -> Bool {
        guard current.count == next.count else { return true }
        guard !next.isEmpty else { return !current.isEmpty }
        for index in 0..<next.count {
            if abs(current[index] - next[index]) >= publishEpsilon {
                return true
            }
        }
        return false
    }
}
