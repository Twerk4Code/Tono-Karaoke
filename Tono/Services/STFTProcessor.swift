import Accelerate
import Foundation

/// Performs STFT and ISTFT using Apple's vDSP/Accelerate framework.
/// Designed to match PyTorch's torch.stft / torch.istft with center=True, Hann window.
final class STFTProcessor: @unchecked Sendable {

    let nFFT: Int
    let hopLength: Int
    let winLength: Int

    /// Hann window of length winLength
    private let window: [Float]
    /// vDSP FFT setup (radix-2, log2(nFFT))
    private let fftSetup: FFTSetup

    init(nFFT: Int = 2048, hopLength: Int = 512, winLength: Int = 2048) {
        self.nFFT = nFFT
        self.hopLength = hopLength
        self.winLength = winLength

        // Create Hann window (periodic, matching PyTorch's default)
        var win = [Float](repeating: 0, count: winLength)
        vDSP_hann_window(&win, vDSP_Length(winLength), Int32(vDSP_HANN_NORM))
        self.window = win

        let log2n = vDSP_Length(log2(Double(nFFT)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("[STFTProcessor] Failed to create FFT setup for n=\(nFFT)")
        }
        self.fftSetup = setup
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    // MARK: - Forward STFT

    /// Computes the STFT of a single-channel signal.
    /// Returns (real, imag) arrays each of shape [freqBins × timeFrames] stored row-major.
    /// freqBins = nFFT/2 + 1, timeFrames = floor(signalLength / hopLength) + 1
    func stft(signal: [Float]) -> (real: [Float], imag: [Float]) {
        let freqBins = nFFT / 2 + 1
        let padAmount = nFFT / 2
        let padded = [Float](repeating: 0, count: padAmount) + signal + [Float](repeating: 0, count: padAmount)

        let timeFrames = (padded.count - nFFT) / hopLength + 1

        var realOut = [Float](repeating: 0, count: freqBins * timeFrames)
        var imagOut = [Float](repeating: 0, count: freqBins * timeFrames)

        var frame = [Float](repeating: 0, count: nFFT)
        let halfN = nFFT / 2
        var splitReal = [Float](repeating: 0, count: halfN)
        var splitImag = [Float](repeating: 0, count: halfN)

        let log2n = vDSP_Length(log2(Double(nFFT)))

        for t in 0..<timeFrames {
            let start = t * hopLength

            // Extract frame and apply window
            for i in 0..<nFFT {
                let sample = (start + i < padded.count) ? padded[start + i] : 0
                frame[i] = (i < winLength) ? sample * window[i] : 0
            }

            // Pack interleaved → split complex
            for i in 0..<halfN {
                splitReal[i] = frame[2 * i]
                splitImag[i] = frame[2 * i + 1]
            }

            // Forward FFT — use withUnsafeMutableBufferPointer for stable pointers (Swift 6)
            splitReal.withUnsafeMutableBufferPointer { realBuf in
                splitImag.withUnsafeMutableBufferPointer { imagBuf in
                    var sc = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &sc, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }

            // Unpack: vDSP packs DC into splitReal[0], Nyquist into splitImag[0]
            // Scale factor 0.5 corrects for vDSP's ×2 forward transform
            let scale: Float = 0.5
            let offset = t

            realOut[0 * timeFrames + offset] = splitReal[0] * scale
            imagOut[0 * timeFrames + offset] = 0

            for k in 1..<halfN {
                realOut[k * timeFrames + offset] = splitReal[k] * scale
                imagOut[k * timeFrames + offset] = splitImag[k] * scale
            }

            realOut[halfN * timeFrames + offset] = splitImag[0] * scale
            imagOut[halfN * timeFrames + offset] = 0
        }

        return (realOut, imagOut)
    }

    // MARK: - Inverse STFT

    /// Reconstructs a signal from STFT (real, imag) arrays.
    /// real/imag are [freqBins × timeFrames] row-major. Returns signal of `outputLength` samples.
    func istft(real: [Float], imag: [Float], timeFrames: Int, outputLength: Int) -> [Float] {
        let halfN = nFFT / 2
        let log2n = vDSP_Length(log2(Double(nFFT)))

        let padAmount = nFFT / 2
        let paddedLength = padAmount + outputLength + padAmount
        var output = [Float](repeating: 0, count: paddedLength + nFFT)
        var windowSum = [Float](repeating: 0, count: paddedLength + nFFT)

        var splitReal = [Float](repeating: 0, count: halfN)
        var splitImag = [Float](repeating: 0, count: halfN)
        var frame = [Float](repeating: 0, count: nFFT)

        for t in 0..<timeFrames {
            let offset = t

            // Pack: DC into splitReal[0], Nyquist into splitImag[0]
            splitReal[0] = real[0 * timeFrames + offset]
            splitImag[0] = real[halfN * timeFrames + offset]

            for k in 1..<halfN {
                splitReal[k] = real[k * timeFrames + offset]
                splitImag[k] = imag[k * timeFrames + offset]
            }

            // Inverse FFT — stable pointers (Swift 6)
            splitReal.withUnsafeMutableBufferPointer { realBuf in
                splitImag.withUnsafeMutableBufferPointer { imagBuf in
                    var sc = DSPSplitComplex(realp: realBuf.baseAddress!, imagp: imagBuf.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &sc, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                }
            }

            // Unpack split complex → interleaved, normalise by 1/nFFT
            let scale = 1.0 / Float(nFFT)
            for i in 0..<halfN {
                frame[2 * i]     = splitReal[i] * scale
                frame[2 * i + 1] = splitImag[i] * scale
            }

            // Overlap-add with synthesis window
            let start = t * hopLength
            for i in 0..<winLength {
                let w = window[i]
                output[start + i]    += frame[i] * w
                windowSum[start + i] += w * w
            }
        }

        // Normalise by window sum (COLA condition)
        for i in 0..<output.count {
            if windowSum[i] > 1e-8 {
                output[i] /= windowSum[i]
            }
        }

        // Remove center-padding
        let startIdx = padAmount
        let endIdx = startIdx + outputLength
        return Array(output[startIdx..<min(endIdx, output.count)])
    }
}
