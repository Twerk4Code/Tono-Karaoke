import Foundation
import Metal
import Accelerate

/// GPU-accelerated audio post-processing for the vocal separation pipeline.
///
/// Provides Metal compute kernels for:
/// - Overlap-add with trapezoidal fade windowing (matches Python `demix_track` reference)
/// - Normalization (result / weight_sum)
/// - Signal subtraction (instrumental = original − vocals)
///
/// Falls back to CPU (Accelerate/scalar) if Metal is unavailable.
final class MetalAudioProcessor: @unchecked Sendable {

    // MARK: - Metal State

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let overlapAddPipeline: MTLComputePipelineState?
    private let normalizePipeline: MTLComputePipelineState?
    private let subtractPipeline: MTLComputePipelineState?

    /// True if all Metal pipelines compiled successfully.
    let isGPUAvailable: Bool

    // MARK: - Init

    init() {
        guard let mtlDevice = MTLCreateSystemDefaultDevice(),
              let queue = mtlDevice.makeCommandQueue() else {
            print("[MetalAudioProcessor] Metal not available — using CPU fallback.")
            self.device = nil
            self.commandQueue = nil
            self.overlapAddPipeline = nil
            self.normalizePipeline = nil
            self.subtractPipeline = nil
            self.isGPUAvailable = false
            return
        }

        self.device = mtlDevice
        self.commandQueue = queue

        // Load shader library from the app bundle
        var oaPipeline: MTLComputePipelineState?
        var normPipeline: MTLComputePipelineState?
        var subPipeline: MTLComputePipelineState?
        var gpuReady = false

        do {
            let library = try mtlDevice.makeDefaultLibrary(bundle: Bundle.main)
            guard let overlapFn = library.makeFunction(name: "overlap_add"),
                  let normFn = library.makeFunction(name: "normalize_divide"),
                  let subFn = library.makeFunction(name: "subtract_signals") else {
                print("[MetalAudioProcessor] Missing Metal shader entry points — using CPU fallback.")
                self.overlapAddPipeline = nil
                self.normalizePipeline = nil
                self.subtractPipeline = nil
                self.isGPUAvailable = false
                return
            }

            oaPipeline = try mtlDevice.makeComputePipelineState(function: overlapFn)
            normPipeline = try mtlDevice.makeComputePipelineState(function: normFn)
            subPipeline = try mtlDevice.makeComputePipelineState(function: subFn)
            gpuReady = true

            print("[MetalAudioProcessor] GPU ready: \(mtlDevice.name)")
        } catch {
            print("[MetalAudioProcessor] Shader compilation failed: \(error) — using CPU fallback.")
        }

        self.overlapAddPipeline = oaPipeline
        self.normalizePipeline = normPipeline
        self.subtractPipeline = subPipeline
        self.isGPUAvailable = gpuReady
    }

    // MARK: - Overlap-Add (GPU)

    /// Accumulates a chunk into the output buffers using trapezoidal fade windowing on the GPU.
    ///
    /// - Parameters:
    ///   - chunkL: Left channel output from CoreML, length = chunkSize
    ///   - chunkR: Right channel output from CoreML, length = chunkSize
    ///   - accumL: Mutable left channel accumulator (full song length)
    ///   - accumR: Mutable right channel accumulator (full song length)
    ///   - weightSum: Mutable per-sample weight accumulator
    ///   - chunkOffset: Sample offset into the accumulator for this chunk
    ///   - chunkLength: Number of valid samples (may be < chunkSize for final chunk)
    ///   - chunkSize: Full chunk size from model config
    ///   - fadeSize: Fade region length (chunkSize / 10)
    ///   - isFirst: True if this is the first chunk (skip fade-in)
    ///   - isLast: True if this is the last chunk (skip fade-out)
    func overlapAdd(
        chunkL: [Float], chunkR: [Float],
        accumL: inout [Float], accumR: inout [Float],
        weightSum: inout [Float],
        chunkOffset: Int, chunkLength: Int,
        chunkSize: Int, fadeSize: Int,
        isFirst: Bool, isLast: Bool
    ) {
        if isGPUAvailable {
            overlapAddGPU(
                chunkL: chunkL, chunkR: chunkR,
                accumL: &accumL, accumR: &accumR,
                weightSum: &weightSum,
                chunkOffset: chunkOffset, chunkLength: chunkLength,
                chunkSize: chunkSize, fadeSize: fadeSize,
                isFirst: isFirst, isLast: isLast
            )
        } else {
            overlapAddCPU(
                chunkL: chunkL, chunkR: chunkR,
                accumL: &accumL, accumR: &accumR,
                weightSum: &weightSum,
                chunkOffset: chunkOffset, chunkLength: chunkLength,
                chunkSize: chunkSize, fadeSize: fadeSize,
                isFirst: isFirst, isLast: isLast
            )
        }
    }

    private func overlapAddGPU(
        chunkL: [Float], chunkR: [Float],
        accumL: inout [Float], accumR: inout [Float],
        weightSum: inout [Float],
        chunkOffset: Int, chunkLength: Int,
        chunkSize: Int, fadeSize: Int,
        isFirst: Bool, isLast: Bool
    ) {
        guard let device, let queue = commandQueue, let pipeline = overlapAddPipeline else { return }

        // Interleave L/R for the GPU kernel
        var interleaved = [Float](repeating: 0, count: chunkLength * 2)
        for i in 0..<chunkLength {
            interleaved[i * 2]     = chunkL[i]
            interleaved[i * 2 + 1] = chunkR[i]
        }

        // Create GPU buffers
        let chunkBuf = device.makeBuffer(
            bytes: interleaved, length: interleaved.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )!

        // For accumulator buffers, we need to copy the relevant slice, process, and copy back.
        // Using shared mode so CPU and GPU can both access.
        let sliceLen = chunkLength
        let accumLSlice = Array(accumL[chunkOffset..<(chunkOffset + sliceLen)])
        let accumRSlice = Array(accumR[chunkOffset..<(chunkOffset + sliceLen)])
        let weightSlice = Array(weightSum[chunkOffset..<(chunkOffset + sliceLen)])

        let accumLBuf = device.makeBuffer(
            bytes: accumLSlice, length: sliceLen * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )!
        let accumRBuf = device.makeBuffer(
            bytes: accumRSlice, length: sliceLen * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )!
        let weightBuf = device.makeBuffer(
            bytes: weightSlice, length: sliceLen * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )!

        // Parameters struct — must match AudioSeparation.metal OverlapAddParams layout
        var params = (
            UInt32(0),                          // chunk_offset = 0 (working on slice)
            UInt32(chunkLength),                 // chunk_length
            UInt32(chunkSize),                   // chunk_size
            UInt32(fadeSize),                    // fade_size
            UInt32(isFirst ? 1 : 0),             // is_first_chunk
            UInt32(isLast ? 1 : 0)               // is_last_chunk
        )

        let paramsBuf = device.makeBuffer(
            bytes: &params, length: MemoryLayout.size(ofValue: params),
            options: .storageModeShared
        )!

        // Encode and dispatch
        guard let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(chunkBuf, offset: 0, index: 0)
        encoder.setBuffer(accumLBuf, offset: 0, index: 1)
        encoder.setBuffer(accumRBuf, offset: 0, index: 2)
        encoder.setBuffer(weightBuf, offset: 0, index: 3)
        encoder.setBuffer(paramsBuf, offset: 0, index: 4)

        let threadGroupSize = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        let gridSize = MTLSize(width: chunkLength, height: 1, depth: 1)
        let groupSize = MTLSize(width: threadGroupSize, height: 1, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: groupSize)
        encoder.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Copy results back from GPU buffers
        let accumLPtr = accumLBuf.contents().bindMemory(to: Float.self, capacity: sliceLen)
        let accumRPtr = accumRBuf.contents().bindMemory(to: Float.self, capacity: sliceLen)
        let weightPtr = weightBuf.contents().bindMemory(to: Float.self, capacity: sliceLen)

        for i in 0..<sliceLen {
            accumL[chunkOffset + i] = accumLPtr[i]
            accumR[chunkOffset + i] = accumRPtr[i]
            weightSum[chunkOffset + i] = weightPtr[i]
        }
    }

    // MARK: - Normalize (GPU)

    /// Divides accumulated L/R by weight sum. Operates in-place.
    func normalize(
        accumL: inout [Float], accumR: inout [Float],
        weightSum: [Float], count: Int
    ) {
        guard count > 0 else { return }
        if isGPUAvailable {
            normalizeGPU(accumL: &accumL, accumR: &accumR, weightSum: weightSum, count: count)
        } else {
            normalizeCPU(accumL: &accumL, accumR: &accumR, weightSum: weightSum, count: count)
        }
    }

    private func normalizeGPU(
        accumL: inout [Float], accumR: inout [Float],
        weightSum: [Float], count: Int
    ) {
        guard let device, let queue = commandQueue, let pipeline = normalizePipeline else { return }

        let byteLen = count * MemoryLayout<Float>.stride
        let accumLBuf = device.makeBuffer(bytes: accumL, length: byteLen, options: .storageModeShared)!
        let accumRBuf = device.makeBuffer(bytes: accumR, length: byteLen, options: .storageModeShared)!
        let weightBuf = device.makeBuffer(bytes: weightSum, length: byteLen, options: .storageModeShared)!

        guard let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(accumLBuf, offset: 0, index: 0)
        encoder.setBuffer(accumRBuf, offset: 0, index: 1)
        encoder.setBuffer(weightBuf, offset: 0, index: 2)

        let threadGroupSize = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadGroupSize, height: 1, depth: 1)
        )
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Copy back
        let lPtr = accumLBuf.contents().bindMemory(to: Float.self, capacity: count)
        let rPtr = accumRBuf.contents().bindMemory(to: Float.self, capacity: count)
        accumL.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: lPtr, count: count) }
        accumR.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: rPtr, count: count) }
    }

    // MARK: - Subtract (GPU)

    /// Computes instrumental = original − vocals for a single channel.
    func subtract(original: [Float], vocals: [Float]) -> [Float] {
        let count = original.count
        guard count > 0 else { return [] }
        if isGPUAvailable {
            return subtractGPU(original: original, vocals: vocals, count: count)
        } else {
            return subtractCPU(original: original, vocals: vocals, count: count)
        }
    }

    private func subtractGPU(original: [Float], vocals: [Float], count: Int) -> [Float] {
        guard let device, let queue = commandQueue, let pipeline = subtractPipeline else {
            return subtractCPU(original: original, vocals: vocals, count: count)
        }

        let byteLen = count * MemoryLayout<Float>.stride
        let origBuf = device.makeBuffer(bytes: original, length: byteLen, options: .storageModeShared)!
        let vocalBuf = device.makeBuffer(bytes: vocals, length: byteLen, options: .storageModeShared)!
        let resultBuf = device.makeBuffer(length: byteLen, options: .storageModeShared)!

        guard let cmdBuf = queue.makeCommandBuffer(),
              let encoder = cmdBuf.makeComputeCommandEncoder() else {
            return subtractCPU(original: original, vocals: vocals, count: count)
        }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(origBuf, offset: 0, index: 0)
        encoder.setBuffer(vocalBuf, offset: 0, index: 1)
        encoder.setBuffer(resultBuf, offset: 0, index: 2)

        let threadGroupSize = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadGroupSize, height: 1, depth: 1)
        )
        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        var result = [Float](repeating: 0, count: count)
        let ptr = resultBuf.contents().bindMemory(to: Float.self, capacity: count)
        result.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: ptr, count: count) }
        return result
    }

    // MARK: - CPU Fallbacks

    private func overlapAddCPU(
        chunkL: [Float], chunkR: [Float],
        accumL: inout [Float], accumR: inout [Float],
        weightSum: inout [Float],
        chunkOffset: Int, chunkLength: Int,
        chunkSize: Int, fadeSize: Int,
        isFirst: Bool, isLast: Bool
    ) {
        for i in 0..<chunkLength {
            var w: Float = 1.0

            if i < fadeSize && !isFirst {
                w = Float(i) / Float(fadeSize)
            } else if i >= (chunkSize - fadeSize) && !isLast {
                let fadePos = i - (chunkSize - fadeSize)
                w = 1.0 - Float(fadePos) / Float(fadeSize)
            }

            let idx = chunkOffset + i
            accumL[idx]    += chunkL[i] * w
            accumR[idx]    += chunkR[i] * w
            weightSum[idx] += w
        }
    }

    private func normalizeCPU(
        accumL: inout [Float], accumR: inout [Float],
        weightSum: [Float], count: Int
    ) {
        // Use vDSP for vectorized divide where possible
        var safeWeights = weightSum
        for i in 0..<count where safeWeights[i] < 1e-8 {
            safeWeights[i] = 1.0  // prevent NaN; accum is 0 here anyway
        }
        vDSP_vdiv(safeWeights, 1, accumL, 1, &accumL, 1, vDSP_Length(count))
        vDSP_vdiv(safeWeights, 1, accumR, 1, &accumR, 1, vDSP_Length(count))
    }

    private func subtractCPU(original: [Float], vocals: [Float], count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        // vDSP_vsub computes C = B - A (note the reversed order)
        vDSP_vsub(vocals, 1, original, 1, &result, 1, vDSP_Length(count))
        return result
    }
}
