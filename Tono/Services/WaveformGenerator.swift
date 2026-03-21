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
        let totalFrames = Int(file.length)

        guard totalFrames > 0 else { return [] }
        let safeTargetSampleCount = max(1, targetSamples)
        let samplesPerBin = max(1, totalFrames / safeTargetSampleCount)
        let actualBins = Int(ceil(Double(totalFrames) / Double(samplesPerBin)))
        guard actualBins > 0 else { return [] }

        var sumSquares = [Float](repeating: 0, count: actualBins)
        var counts = [Int](repeating: 0, count: actualBins)

        let chunkFrameCapacity = AVAudioFrameCount(max(4096, min(32768, samplesPerBin * 4)))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrameCapacity) else {
            return []
        }
        guard let channelData = buffer.floatChannelData else { return [] }

        let channelCount = Int(format.channelCount)
        var processedFrames = 0

        while processedFrames < totalFrames {
            let remaining = totalFrames - processedFrames
            let frameCountToRead = AVAudioFrameCount(min(remaining, Int(chunkFrameCapacity)))
            buffer.frameLength = 0
            try file.read(into: buffer, frameCount: frameCountToRead)

            let frameCount = Int(buffer.frameLength)
            if frameCount == 0 { break }

            if channelCount == 1 {
                let mono = channelData[0]
                for frameIndex in 0..<frameCount {
                    let globalFrameIndex = processedFrames + frameIndex
                    let bin = min(globalFrameIndex / samplesPerBin, actualBins - 1)
                    let sample = mono[frameIndex]
                    sumSquares[bin] += sample * sample
                    counts[bin] += 1
                }
            } else {
                let left = channelData[0]
                let right = channelData[1]
                for frameIndex in 0..<frameCount {
                    let globalFrameIndex = processedFrames + frameIndex
                    let bin = min(globalFrameIndex / samplesPerBin, actualBins - 1)
                    let sample = 0.5 * (left[frameIndex] + right[frameIndex])
                    sumSquares[bin] += sample * sample
                    counts[bin] += 1
                }
            }

            processedFrames += frameCount
        }

        // Compute RMS per bin.
        var waveform = [Float](repeating: 0, count: actualBins)
        for i in 0..<actualBins {
            guard counts[i] > 0 else { continue }
            waveform[i] = sqrtf(sumSquares[i] / Float(counts[i]))
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
