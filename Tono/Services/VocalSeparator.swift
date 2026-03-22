import Foundation
@preconcurrency import AVFoundation

/// Separates vocals from instrumental using an end-to-end MelBandRoFormer PyTorch model.
///
/// Pipeline:
///   1. Decode audio → 44100 Hz stereo Float32
///   2. Reflect-pad by `border` samples on each side
///   3. Process in overlapping chunks with trapezoidal fade windowing
///   4. Per chunk: pass L/R float arrays → libtorch inference → vocals L/R
///   5. GPU-accelerated overlap-add (MetalAudioProcessor) with trapezoidal window
///   6. Normalize by accumulated window weights
///   7. Strip reflect-padding, write vocal WAV
///   8. Instrumental = original − vocals (GPU-accelerated subtraction)
final class VocalSeparator: @unchecked Sendable {

    enum SeparationError: Error, LocalizedError {
        case modelNotFound
        case processingFailed
        case fileReadError
        case formatConversionFailed
        case inferenceError(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .modelNotFound: "MelBandRoFormer model not found in app bundle."
            case .processingFailed: "Audio processing failed."
            case .fileReadError: "Could not read the audio file."
            case .formatConversionFailed: "Audio format conversion failed."
            case .inferenceError(let msg): "ML inference error: \(msg)"
            case .cancelled: "Separation was cancelled."
            }
        }
    }

    // MARK: - Model Constants
    // Match the KimberleyJSN/melbandroformer config.

    private static let sampleRate: Double = 44100
    private static let chunkSize  = 352800       // 8 seconds at 44100 Hz
    private static let numOverlap = 2            // overlap factor
    private static let step       = chunkSize / numOverlap   // 176400
    private static let fadeSize   = chunkSize / 10           // 35280
    private static let border     = chunkSize - step         // 176400

    // MARK: - Metal Processor

    private let metalProcessor = MetalAudioProcessor()

    // MARK: - Cached Model

    private nonisolated(unsafe) static var cachedModule: TorchModule?
    private static let modelLock = NSLock()

    var isModelLoaded: Bool { Self.cachedModule != nil }

    /// Releases the cached TorchScript model to free memory.
    /// Call after separation completes if the model is not needed imminently.
    func releaseModel() {
        Self.modelLock.lock()
        defer { Self.modelLock.unlock() }
        Self.cachedModule = nil
        print("[VocalSeparator] Model released from memory.")
    }

    private func loadModelIfNeeded() throws -> TorchModule {
        Self.modelLock.lock()
        defer { Self.modelLock.unlock() }

        if let module = Self.cachedModule { return module }

        guard let modelPath = findModelPath() else {
            print("[VocalSeparator] MelBandRoFormer.pt not found.")
            throw SeparationError.modelNotFound
        }

        guard let module = TorchModule(fileAtPath: modelPath) else {
            throw SeparationError.inferenceError("Failed to load TorchScript model at \(modelPath)")
        }

        Self.cachedModule = module
        print("[VocalSeparator] Model loaded from: \(modelPath)")
        print("[VocalSeparator] Metal post-processing: \(metalProcessor.isGPUAvailable ? "enabled" : "CPU fallback")")
        return module
    }

    private func findModelPath() -> String? {
        let modelName = "MelBandRoformer"

        // Check bundle resource
        if let path = Bundle.main.path(forResource: modelName, ofType: "pt") {
            return path
        }

        // Check common resource locations
        let candidates: [String] = [
            Bundle.main.bundlePath + "/Contents/Resources/\(modelName).pt",
            Bundle.main.bundlePath + "/\(modelName).pt",
        ]

        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Public API

    func separate(
        inputURL: URL,
        outputDirectory: URL,
        songID: UUID
    ) -> (stream: AsyncThrowingStream<Double, Error>, vocalURL: URL, instrumentalURL: URL) {
        let vocalURL = outputDirectory.appendingPathComponent("\(songID.uuidString)_vocals.wav")
        let instrumentalURL = outputDirectory.appendingPathComponent("\(songID.uuidString)_instrumental.wav")

        let stream = AsyncThrowingStream<Double, Error> { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    // ── Load model ──
                    let module = try self.loadModelIfNeeded()
                    continuation.yield(0.05)

                    // ── Decode audio → 44100 Hz stereo Float32 ──
                    let (audioL, audioR, totalFrames) = try self.decodeStereo(url: inputURL)
                    continuation.yield(0.10)

                    // ── Reflect-pad the audio (matches Python demix_track) ──
                    let C = Self.chunkSize
                    let step = Self.step
                    let fadeSize = Self.fadeSize
                    let border = Self.border

                    let (paddedL, paddedR, paddedLen) = self.reflectPad(
                        L: audioL, R: audioR, totalFrames: totalFrames, border: border
                    )

                    // ── Compute chunk layout ──
                    let nChunks = (paddedLen + step - 1) / step

                    var vocalL    = [Float](repeating: 0, count: paddedLen)
                    var vocalR    = [Float](repeating: 0, count: paddedLen)
                    var weightSum = [Float](repeating: 0, count: paddedLen)
                    var chunkInputL = [Float](repeating: 0, count: C)
                    var chunkInputR = [Float](repeating: 0, count: C)
                    var chunkVocalL = [Float](repeating: 0, count: C)
                    var chunkVocalR = [Float](repeating: 0, count: C)

                    // ── Process each chunk ──
                    // NOTE: Each iteration is wrapped in autoreleasepool to ensure
                    // Metal buffers and libtorch Obj-C bridge objects are freed
                    // promptly. Without this, Task.detached has no deterministic
                    // autorelease boundaries and temporaries from ALL chunks
                    // accumulate until the Task completes — causing massive memory growth.
                    var i = 0
                    var chunkIdx = 0
                    while i < paddedLen {
                        try autoreleasepool {
                            // Extract chunk, pad if shorter than chunkSize
                            let remaining = paddedLen - i
                            let partLen = min(C, remaining)

                            chunkInputL.replaceSubrange(0..<partLen, with: paddedL[i..<(i + partLen)])
                            chunkInputR.replaceSubrange(0..<partLen, with: paddedR[i..<(i + partLen)])

                            // Pad short chunks via reflection or zero-fill
                            if partLen < C {
                                for j in partLen..<C {
                                    chunkInputL[j] = 0
                                    chunkInputR[j] = 0
                                }
                                if partLen > C / 2 + 1 {
                                    for j in 0..<(C - partLen) {
                                        let srcIdx = partLen - 1 - j
                                        chunkInputL[partLen + j] = chunkInputL[max(0, srcIdx)]
                                        chunkInputR[partLen + j] = chunkInputR[max(0, srcIdx)]
                                    }
                                }
                            }

                            // libtorch inference: L/R float arrays → model → vocal L/R
                            let success = chunkInputL.withUnsafeBufferPointer { leftBuf in
                                chunkInputR.withUnsafeBufferPointer { rightBuf in
                                    chunkVocalL.withUnsafeMutableBufferPointer { outLeftBuf in
                                        chunkVocalR.withUnsafeMutableBufferPointer { outRightBuf in
                                            module.predict(
                                                left: leftBuf.baseAddress!,
                                                right: rightBuf.baseAddress!,
                                                length: Int32(C),
                                                outputLeft: outLeftBuf.baseAddress!,
                                                outputRight: outRightBuf.baseAddress!
                                            )
                                        }
                                    }
                                }
                            }

                            if !success {
                                throw SeparationError.inferenceError("libtorch inference failed on chunk \(chunkIdx)")
                            }

                            // GPU-accelerated overlap-add with trapezoidal fade
                            let isFirst = (i == 0)
                            let isLast = (i + C >= paddedLen)

                            self.metalProcessor.overlapAdd(
                                chunkL: chunkVocalL, chunkR: chunkVocalR,
                                accumL: &vocalL, accumR: &vocalR,
                                weightSum: &weightSum,
                                chunkOffset: i, chunkLength: min(partLen, C),
                                chunkSize: C, fadeSize: fadeSize,
                                isFirst: isFirst, isLast: isLast
                            )

                            i += step
                            chunkIdx += 1
                            let progress = 0.10 + 0.75 * Double(chunkIdx) / Double(nChunks)
                            continuation.yield(min(progress, 0.85))
                        }
                    }

                    // ── Normalize by window weights (GPU) ──
                    self.metalProcessor.normalize(
                        accumL: &vocalL, accumR: &vocalR,
                        weightSum: weightSum, count: paddedLen
                    )

                    // ── Strip reflect-padding ──
                    let shouldStrip = totalFrames > 2 * border && border > 0
                    let finalVocalL: [Float]
                    let finalVocalR: [Float]
                    if shouldStrip {
                        finalVocalL = Array(vocalL[border..<(border + totalFrames)])
                        finalVocalR = Array(vocalR[border..<(border + totalFrames)])
                    } else {
                        finalVocalL = Array(vocalL[0..<totalFrames])
                        finalVocalR = Array(vocalR[0..<totalFrames])
                    }

                    // ── Write vocal stem ──
                    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                    try self.writeStereoWAV(L: finalVocalL, R: finalVocalR, frameCount: totalFrames, to: vocalURL)
                    continuation.yield(0.90)

                    // ── Instrumental = original − vocals (GPU) ──
                    let instrL = self.metalProcessor.subtract(original: audioL, vocals: finalVocalL)
                    let instrR = self.metalProcessor.subtract(original: audioR, vocals: finalVocalR)
                    try self.writeStereoWAV(L: instrL, R: instrR, frameCount: totalFrames, to: instrumentalURL)

                    // Release the model to free hundreds of MB of weight tensors
                    // and flush libtorch's internal memory caches.
                    self.releaseModel()
                    self.metalProcessor.releaseReusableBuffers()

                    continuation.yield(1.0)
                    continuation.finish()
                } catch {
                    self.releaseModel()
                    self.metalProcessor.releaseReusableBuffers()
                    continuation.finish(throwing: error)
                }
            }
        }

        return (stream, vocalURL, instrumentalURL)
    }

    // MARK: - Reflect Padding

    /// Pads audio with reflected samples at both ends (matches Python `nn.functional.pad(mode='reflect')`).
    private func reflectPad(
        L: [Float], R: [Float], totalFrames: Int, border: Int
    ) -> (L: [Float], R: [Float], paddedLength: Int) {
        guard totalFrames > 2 * border && border > 0 else {
            return (L, R, totalFrames)
        }

        let paddedLen = totalFrames + 2 * border
        var pL = [Float](repeating: 0, count: paddedLen)
        var pR = [Float](repeating: 0, count: paddedLen)

        // Leading reflection
        for i in 0..<border {
            pL[i] = L[border - i]
            pR[i] = R[border - i]
        }

        // Original signal
        pL.replaceSubrange(border..<(border + totalFrames), with: L)
        pR.replaceSubrange(border..<(border + totalFrames), with: R)

        // Trailing reflection
        for i in 0..<border {
            pL[border + totalFrames + i] = L[totalFrames - 2 - i]
            pR[border + totalFrames + i] = R[totalFrames - 2 - i]
        }

        return (pL, pR, paddedLen)
    }

    // MARK: - Audio I/O

    /// Decodes any audio file to 44100 Hz stereo Float32, returning separate L and R channels.
    private func decodeStereo(url: URL) throws -> (L: [Float], R: [Float], frameCount: Int) {
        let audioFile = try AVAudioFile(forReading: url)
        let sourceFormat = audioFile.processingFormat

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 2,
            interleaved: false
        ) else { throw SeparationError.formatConversionFailed }

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(audioFile.length)
        ) else { throw SeparationError.formatConversionFailed }

        try audioFile.read(into: sourceBuffer)

        let pcmBuffer: AVAudioPCMBuffer
        if sourceFormat.sampleRate == Self.sampleRate && sourceFormat.channelCount == 2
            && sourceFormat.commonFormat == .pcmFormatFloat32 {
            pcmBuffer = sourceBuffer
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                throw SeparationError.formatConversionFailed
            }
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else {
                throw SeparationError.formatConversionFailed
            }
            var convErr: NSError?
            converter.convert(to: converted, error: &convErr) { _, outStatus in
                outStatus.pointee = .haveData
                return sourceBuffer
            }
            if let err = convErr { throw SeparationError.inferenceError(err.localizedDescription) }
            pcmBuffer = converted
        }

        guard let channelData = pcmBuffer.floatChannelData else {
            throw SeparationError.processingFailed
        }

        let frameCount = Int(pcmBuffer.frameLength)
        guard frameCount > 0 else {
            throw SeparationError.fileReadError
        }

        // Handle mono input by duplicating to stereo
        let L = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        let R: [Float]
        if pcmBuffer.format.channelCount >= 2 {
            R = Array(UnsafeBufferPointer(start: channelData[1], count: frameCount))
        } else {
            R = L
        }

        return (L, R, frameCount)
    }

    /// Writes separate L/R float arrays as a stereo 44100 Hz WAV.
    private func writeStereoWAV(L: [Float], R: [Float], frameCount: Int, to url: URL) throws {
        guard frameCount > 0, L.count >= frameCount, R.count >= frameCount else {
            throw SeparationError.processingFailed
        }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: 2,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { throw SeparationError.formatConversionFailed }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        guard let ch = buffer.floatChannelData else { throw SeparationError.processingFailed }

        L.withUnsafeBufferPointer { src in
            if let srcPtr = src.baseAddress {
                ch[0].update(from: srcPtr, count: frameCount)
            }
        }
        R.withUnsafeBufferPointer { src in
            if let srcPtr = src.baseAddress {
                ch[1].update(from: srcPtr, count: frameCount)
            }
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
