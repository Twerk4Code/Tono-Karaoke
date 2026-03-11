#include <metal_stdlib>
using namespace metal;

// ─────────────────────────────────────────────────────────
//  AudioSeparation.metal — GPU compute kernels for Tono
//
//  Kernels:
//   1. overlap_add      — accumulate chunk output with trapezoidal fade window
//   2. normalize_divide — result / counter (with NaN protection)
//   3. subtract_signals — instrumental = original - vocals
// ─────────────────────────────────────────────────────────

/// Parameters passed to the overlap_add kernel via a constant buffer.
struct OverlapAddParams {
    uint chunk_offset;     // sample offset into the output accumulator
    uint chunk_length;     // number of valid samples in this chunk (may be < chunk_size for last chunk)
    uint chunk_size;       // full chunk size (352800)
    uint fade_size;        // fade region length (chunk_size / 10)
    uint is_first_chunk;   // 1 if first chunk (no fade-in), 0 otherwise
    uint is_last_chunk;    // 1 if last chunk (no fade-out), 0 otherwise
};

/// Overlap-add a single chunk into the output accumulator with trapezoidal windowing.
///
/// The trapezoidal window matches the Python reference implementation:
///   - Linear fade-in over [0, fade_size) samples
///   - Flat 1.0 over [fade_size, chunk_size - fade_size)
///   - Linear fade-out over [chunk_size - fade_size, chunk_size)
///   - First chunk: fade-in region is forced to 1.0
///   - Last chunk: fade-out region is forced to 1.0
///
/// Each thread processes one sample index within the chunk.
/// Two channels (L/R) are interleaved: chunk_data layout is [L0, R0, L1, R1, ...]
kernel void overlap_add(
    device const float* chunk_data      [[buffer(0)]],  // [2 * chunk_size] interleaved L/R
    device float*       accum_L         [[buffer(1)]],   // output accumulator, left channel
    device float*       accum_R         [[buffer(2)]],   // output accumulator, right channel
    device float*       weight_sum      [[buffer(3)]],   // per-sample window weight accumulator
    constant OverlapAddParams& params   [[buffer(4)]],
    uint gid                            [[thread_position_in_grid]]
) {
    if (gid >= params.chunk_length) return;

    // Compute trapezoidal window value for this sample position
    float window_val = 1.0;

    if (gid < params.fade_size && params.is_first_chunk == 0) {
        // Fade-in region (linear ramp 0→1)
        window_val = float(gid) / float(params.fade_size);
    } else if (gid >= (params.chunk_size - params.fade_size) && params.is_last_chunk == 0) {
        // Fade-out region (linear ramp 1→0)
        uint fade_pos = gid - (params.chunk_size - params.fade_size);
        window_val = 1.0 - float(fade_pos) / float(params.fade_size);
    }

    // Read interleaved stereo from chunk
    float sample_L = chunk_data[gid * 2];
    float sample_R = chunk_data[gid * 2 + 1];

    // Accumulate windowed samples
    uint out_idx = params.chunk_offset + gid;
    accum_L[out_idx]    += sample_L * window_val;
    accum_R[out_idx]    += sample_R * window_val;
    weight_sum[out_idx] += window_val;
}

/// Normalize accumulated result by dividing by the weight sum.
/// Protects against division by zero (weight < epsilon → output = 0).
kernel void normalize_divide(
    device float* accum_L       [[buffer(0)]],
    device float* accum_R       [[buffer(1)]],
    device const float* weights [[buffer(2)]],
    uint gid                    [[thread_position_in_grid]]
) {
    float w = weights[gid];
    if (w > 1e-8) {
        accum_L[gid] /= w;
        accum_R[gid] /= w;
    } else {
        accum_L[gid] = 0.0;
        accum_R[gid] = 0.0;
    }
}

/// Compute instrumental = original - vocals (element-wise subtraction).
kernel void subtract_signals(
    device const float* original [[buffer(0)]],
    device const float* vocals   [[buffer(1)]],
    device float*       result   [[buffer(2)]],
    uint gid                     [[thread_position_in_grid]]
) {
    result[gid] = original[gid] - vocals[gid];
}
