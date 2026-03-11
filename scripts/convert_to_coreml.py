#!/usr/bin/env python3
"""
convert_to_coreml.py — Convert MelBandRoformer PyTorch checkpoint to CoreML .mlpackage

Usage:
    1. Clone the model repo:
       git clone https://github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model.git
       cd Mel-Band-Roformer-Vocal-Model

    2. Install dependencies:
       pip install torch torchaudio coremltools omegaconf beartype rotary_embedding_torch einops librosa

    3. Download the checkpoint from HuggingFace:
       wget https://huggingface.co/KimberleyJSN/melbandroformer/resolve/main/MelBandRoformer.ckpt

    4. Run this script from the repo root:
       python /path/to/convert_to_coreml.py \
           --checkpoint MelBandRoformer.ckpt \
           --config configs/config_vocals_mel_band_roformer.yaml \
           --output MelBandRoformer.mlpackage

    The generated .mlpackage should be added to the Tono Xcode project under Resources/.

Requirements:
    - Python 3.10+
    - torch >= 2.0.1
    - coremltools >= 8.0
    - omegaconf == 2.2.3
    - beartype == 0.14.1
    - rotary_embedding_torch == 0.3.5
    - einops == 0.6.1
"""

import argparse
import sys
import os
from pathlib import Path

import torch
import torch.nn as nn
import numpy as np

try:
    import coremltools as ct
except ImportError:
    print("ERROR: coremltools not installed. Run: pip install coremltools>=8.0")
    sys.exit(1)

try:
    from omegaconf import OmegaConf
except ImportError:
    print("ERROR: omegaconf not installed. Run: pip install omegaconf==2.2.3")
    sys.exit(1)


# ──────────────────────────────────────────────
#  Model loading (mirrors the repo's utils.py)
# ──────────────────────────────────────────────

def load_model_from_config(config_path: str, checkpoint_path: str):
    """Load MelBandRoformer from config YAML and checkpoint file."""

    # OmegaConf doesn't support !!python/tuple tags — strip them before loading
    import re
    with open(config_path, "r") as f:
        yaml_text = f.read()
    yaml_text = re.sub(r"!!python/tuple\b", "", yaml_text)
    config = OmegaConf.create(yaml_text)

    chunk_size = config.inference.chunk_size
    sample_rate = config.model.sample_rate
    print(f"[INFO] Config loaded: {config_path}")
    print(f"[INFO] Model type: mel_band_roformer")
    print(f"[INFO] Chunk size: {chunk_size} samples "
          f"({chunk_size / sample_rate:.2f}s)")
    print(f"[INFO] STFT: n_fft={config.model.stft_n_fft}, "
          f"hop={config.model.stft_hop_length}, sr={sample_rate}")

    # Import the model class from the repo — ensure CWD is on sys.path
    cwd = os.getcwd()
    if cwd not in sys.path:
        sys.path.insert(0, cwd)
    try:
        from models.mel_band_roformer import MelBandRoformer
    except ImportError as e:
        print(f"ERROR: Cannot import MelBandRoformer: {e}")
        print("Run this script from the Mel-Band-Roformer-Vocal-Model repo root.")
        sys.exit(1)

    # Convert OmegaConf to plain dict and fix types that beartype enforces
    model_kwargs = OmegaConf.to_container(config.model, resolve=True)
    # multi_stft_resolutions_window_sizes must be a tuple, not a list
    if "multi_stft_resolutions_window_sizes" in model_kwargs:
        model_kwargs["multi_stft_resolutions_window_sizes"] = tuple(
            model_kwargs["multi_stft_resolutions_window_sizes"]
        )
    model = MelBandRoformer(**model_kwargs)

    # Load checkpoint
    state_dict = torch.load(checkpoint_path, map_location="cpu", weights_only=False)

    # Handle potential 'state_dict' wrapper
    if "state_dict" in state_dict:
        state_dict = state_dict["state_dict"]

    # Strip 'module.' prefix from DataParallel checkpoints
    cleaned = {}
    for k, v in state_dict.items():
        key = k.replace("module.", "") if k.startswith("module.") else k
        cleaned[key] = v

    model.load_state_dict(cleaned)
    model.eval()

    total_params = sum(p.numel() for p in model.parameters())
    print(f"[INFO] Model loaded: {total_params / 1e6:.1f}M parameters")

    return model, config


# ──────────────────────────────────────────────
#  End-to-end wrapper for clean CoreML tracing
# ──────────────────────────────────────────────

class MelBandRoformerBackbone(nn.Module):
    """
    Extracts the transformer backbone from MelBandRoformer for CoreML export.
    STFT/ISTFT ops are kept external (handled in Swift via vDSP).

    Uses pure torch reshape/permute ops instead of einops to avoid
    `int` op errors during CoreML conversion.

    Input:  spectrogram_input [batch, num_freq_indices, time_frames, 2]
            — real+imag packed STFT representation after band indexing
    Output: masks_output [batch, 1, num_freq_indices, time_frames, 2]
            — estimated complex mask (as real+imag pairs)
    """

    def __init__(self, model, num_freq_indices: int, time_frames: int):
        super().__init__()
        self.band_split = model.band_split
        self.layers = model.layers
        self.mask_estimators = model.mask_estimators
        # Bake in the fixed dimensions to avoid dynamic shape arithmetic
        self.num_freq = num_freq_indices   # 3958
        self.time_frames = time_frames     # 801
        self.num_bands = 60                # from config
        self.dim = 384                     # from config

    def forward(self, x_input):
        """
        x_input: [1, num_freq, time_frames, 2]
        """
        # [1, F, T, 2] -> [1, T, F, 2] -> [1, T, F*2]
        x = x_input.permute(0, 2, 1, 3).contiguous()
        x = x.view(1, self.time_frames, self.num_freq * 2)

        # Band split: [1, T, F*2] -> [1, T, num_bands, dim]
        x = self.band_split(x)

        # Axial attention layers
        for time_transformer, freq_transformer in self.layers:
            # Time attention: reshape to [num_bands, T, dim]
            x = x.permute(0, 2, 1, 3).contiguous()       # [1, B, T, D]
            x = x.view(self.num_bands, self.time_frames, self.dim)  # [B, T, D]
            x = time_transformer(x)
            x = x.view(1, self.num_bands, self.time_frames, self.dim)  # [1, B, T, D]

            # Freq attention: reshape to [T, num_bands, dim]
            x = x.permute(0, 2, 1, 3).contiguous()       # [1, T, B, D]
            x = x.view(self.time_frames, self.num_bands, self.dim)  # [T, B, D]
            x = freq_transformer(x)
            x = x.view(1, self.time_frames, self.num_bands, self.dim)  # [1, T, B, D]

        # Mask estimation: each fn takes [1, T, B, D] -> [1, T, F*2]
        masks = torch.stack([fn(x) for fn in self.mask_estimators], dim=1)
        # masks: [1, N, T, F*2] -> [1, N, T, F, 2] -> [1, N, F, T, 2]
        masks = masks.view(1, 1, self.time_frames, self.num_freq, 2)
        masks = masks.permute(0, 1, 3, 2, 4).contiguous()

        return masks


# ──────────────────────────────────────────────
#  CoreML conversion
# ──────────────────────────────────────────────

def convert_to_coreml(
    model,
    config,
    output_path: str,
    compute_precision=None,
):
    """Convert the PyTorch model backbone to CoreML .mlpackage format.

    Exports only the transformer backbone (band split → attention → mask estimation).
    STFT/ISTFT ops are kept external (handled in Swift via vDSP/Accelerate).

    Input:  spectrogram_input [1, num_freq_indices, time_frames, 2]
    Output: masks_output      [1, 1, num_freq_indices, time_frames, 2]
    """

    if compute_precision is None:
        compute_precision = ct.precision.FLOAT32

    # Compute dimensions
    chunk_size = config.inference.chunk_size   # 352800
    hop_length = config.model.stft_hop_length  # 441
    n_fft = config.model.stft_n_fft            # 2048
    num_freq_indices = model.freq_indices.shape[0]  # 3958
    time_frames = chunk_size // hop_length + 1      # 801

    print(f"\n[INFO] Backbone I/O shapes:")
    print(f"  Input:  [1, {num_freq_indices}, {time_frames}, 2]")
    print(f"  Output: [1, 1, {num_freq_indices}, {time_frames}, 2]")

    # Wrap: extract only the transformer backbone (no STFT/ISTFT)
    wrapper = MelBandRoformerBackbone(model, num_freq_indices, time_frames)
    wrapper.eval()

    # Create sample input matching backbone dimensions
    sample_input = torch.randn(1, num_freq_indices, time_frames, 2)

    print(f"[INFO] Tracing backbone via torch.jit.trace...")

    with torch.no_grad():
        traced = torch.jit.trace(wrapper, (sample_input,), strict=False, check_trace=False)

    test_output = traced(sample_input)
    print(f"[INFO] Traced output shape: {list(test_output.shape)}")

    print(f"[INFO] Converting to CoreML (precision: {compute_precision})...")

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(
                name="spectrogram_input",
                shape=(1, num_freq_indices, time_frames, 2),
                dtype=np.float32,
            )
        ],
        outputs=[
            ct.TensorType(
                name="masks_output",
                dtype=np.float32,
            )
        ],
        compute_precision=compute_precision,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS15,
        convert_to="mlprogram",
    )

    # Add metadata
    mlmodel.author = "Tono App (converted from KimberleyJSN/melbandroformer)"
    mlmodel.short_description = (
        f"MelBandRoformer vocal separation backbone. "
        f"Input: spectrogram [{num_freq_indices}, {time_frames}, 2]. "
        f"Output: masks [1, {num_freq_indices}, {time_frames}, 2]."
    )
    mlmodel.version = "2.0"

    # Store audio params in user-defined metadata for Swift to read
    # Also export freq_indices and band metadata for the Swift STFT pipeline
    freq_idx_str = ",".join(str(int(x)) for x in model.freq_indices.tolist())
    bands_per_freq_str = ",".join(str(int(x)) for x in model.num_bands_per_freq.tolist())

    mlmodel.user_defined_metadata = {
        "chunk_size": str(chunk_size),
        "sample_rate": str(config.model.sample_rate),
        "n_fft": str(n_fft),
        "hop_length": str(hop_length),
        "win_length": str(config.model.stft_win_length),
        "num_overlap": str(config.inference.num_overlap),
        "model_type": "backbone",
        "input_name": "spectrogram_input",
        "output_name": "masks_output",
        "input_shape": f"[1, {num_freq_indices}, {time_frames}, 2]",
        "output_shape": f"[1, 1, {num_freq_indices}, {time_frames}, 2]",
        "num_freq_indices": str(num_freq_indices),
        "time_frames": str(time_frames),
        "freq_bins": str(n_fft // 2 + 1),
        "freq_indices": freq_idx_str,
        "num_bands_per_freq": bands_per_freq_str,
    }

    # Save
    mlmodel.save(output_path)
    pkg_size = sum(
        f.stat().st_size for f in Path(output_path).rglob("*") if f.is_file()
    ) / (1024 * 1024)
    print(f"\n[SUCCESS] Saved CoreML model: {output_path} ({pkg_size:.1f} MB)")

    return mlmodel


# ──────────────────────────────────────────────
#  Validation
# ──────────────────────────────────────────────

def validate_conversion(pytorch_model, coreml_model, config, tolerance=1e-3):
    """Compare PyTorch and CoreML backbone outputs on the same random input."""
    hop_length = config.model.stft_hop_length
    chunk_size = config.inference.chunk_size
    num_freq_indices = pytorch_model.freq_indices.shape[0]
    time_frames = chunk_size // hop_length + 1

    print(f"\n[INFO] Validating CoreML vs PyTorch backbone (tolerance={tolerance})...")

    # Generate test input matching backbone dimensions
    np.random.seed(42)
    test_np = np.random.randn(1, num_freq_indices, time_frames, 2).astype(np.float32) * 0.1

    # PyTorch inference
    wrapper = MelBandRoformerBackbone(pytorch_model, num_freq_indices, time_frames)
    wrapper.eval()
    with torch.no_grad():
        pt_out = wrapper(torch.from_numpy(test_np)).numpy()

    # CoreML inference
    prediction = coreml_model.predict({"spectrogram_input": test_np})
    cml_out = prediction["masks_output"]

    # Compare
    max_diff = np.max(np.abs(pt_out - cml_out))
    mean_diff = np.mean(np.abs(pt_out - cml_out))
    correlation = np.corrcoef(pt_out.flatten(), cml_out.flatten())[0, 1]

    print(f"  Max absolute difference:  {max_diff:.6f}")
    print(f"  Mean absolute difference: {mean_diff:.6f}")
    print(f"  Pearson correlation:      {correlation:.6f}")

    if max_diff < tolerance:
        print(f"  [PASS] Within tolerance ({tolerance})")
    elif correlation > 0.99:
        print(f"  [WARN] Max diff {max_diff:.4f} exceeds tolerance, "
              f"but correlation {correlation:.4f} is high — likely FP precision differences.")
    else:
        print(f"  [FAIL] Outputs diverge significantly. Check conversion.")

    return max_diff, correlation


# ──────────────────────────────────────────────
#  Main
# ──────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Convert MelBandRoformer PyTorch checkpoint to CoreML .mlpackage"
    )
    parser.add_argument(
        "--checkpoint", "-c",
        required=True,
        help="Path to .ckpt file (e.g., MelBandRoformer.ckpt)",
    )
    parser.add_argument(
        "--config", "-cfg",
        default="configs/config_vocals_mel_band_roformer.yaml",
        help="Path to model config YAML",
    )
    parser.add_argument(
        "--output", "-o",
        default="MelBandRoformer.mlpackage",
        help="Output path for .mlpackage",
    )
    parser.add_argument(
        "--precision",
        choices=["float32", "float16"],
        default="float32",
        help="Compute precision (float32 recommended for quality)",
    )
    parser.add_argument(
        "--no-validate",
        action="store_true",
        help="Skip validation step",
    )

    args = parser.parse_args()

    # Resolve precision
    precision = (
        ct.precision.FLOAT16 if args.precision == "float16"
        else ct.precision.FLOAT32
    )

    # Load model
    print("=" * 60)
    print("  MelBandRoformer -> CoreML Conversion")
    print("=" * 60)

    model, config = load_model_from_config(args.config, args.checkpoint)

    # Convert
    coreml_model = convert_to_coreml(
        model=model,
        config=config,
        output_path=args.output,
        compute_precision=precision,
    )

    # Validate
    if not args.no_validate:
        validate_conversion(model, coreml_model, config)

    print(f"\n{'=' * 60}")
    print(f"  Done! Add {args.output} to Tono/Resources/ in Xcode.")
    print(f"{'=' * 60}")


if __name__ == "__main__":
    main()
