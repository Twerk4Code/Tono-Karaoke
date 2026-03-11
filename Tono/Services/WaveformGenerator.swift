import AVFoundation
import Accelerate

/// Generates downsampled waveform amplitude data from an audio file for visualization.
enum WaveformGenerator {

    /// Generate normalized amplitude samples for waveform display.
    /// - Parameters:
    ///   - url: Audio file URL
    ///   - samplesPerPixel: Number of audio samples to condense into one display sample
    ///   - targetSamples: Desired number of output samples (overrides samplesPerPixel if set)
    /// - Returns: Array of normalized amplitudes (0...1)
    static func generate(from url: URL, targetSamples: Int = 300) async throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)

        guard totalFrames > 0 else { return [] }

        let samplesPerBin = max(1, Int(totalFrames) / targetSamples)
        let actualBins = Int(totalFrames) / samplesPerBin

        guard actualBins > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            return []
        }

        try file.read(into: buffer)

        guard let channelData = buffer.floatChannelData else { return [] }

        // Mix to mono if stereo
        let frameCount = Int(buffer.frameLength)
        var monoSamples = [Float](repeating: 0, count: frameCount)

        if format.channelCount == 1 {
            monoSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        } else {
            let left = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            let right = UnsafeBufferPointer(start: channelData[1], count: frameCount)
            vDSP_vadd(left.baseAddress!, 1, right.baseAddress!, 1, &monoSamples, 1, vDSP_Length(frameCount))
            var half: Float = 0.5
            vDSP_vsmul(monoSamples, 1, &half, &monoSamples, 1, vDSP_Length(frameCount))
        }

        // Compute RMS per bin using Accelerate
        var waveform = [Float](repeating: 0, count: actualBins)

        for i in 0..<actualBins {
            let start = i * samplesPerBin
            let count = min(samplesPerBin, frameCount - start)
            guard count > 0 else { continue }

            var sumSquares: Float = 0
            monoSamples.withUnsafeBufferPointer { ptr in
                vDSP_svesq(ptr.baseAddress! + start, 1, &sumSquares, vDSP_Length(count))
            }
            waveform[i] = sqrtf(sumSquares / Float(count))
        }

        // Normalize to 0...1
        var maxVal: Float = 0
        vDSP_maxv(waveform, 1, &maxVal, vDSP_Length(actualBins))

        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(waveform, 1, &scale, &waveform, 1, vDSP_Length(actualBins))
        }

        return waveform
    }
}
