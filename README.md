# Tono

Tono is a macOS karaoke and vocal performance app. It imports songs, separates vocals from instrumentals on-device, and provides dual-stem playback, mic monitoring, effects, and pitch tracking.
Tono 🎤
Tono is a high-performance, native macOS application designed for vocalists and audio engineers. It bridges the gap between AI-driven stem separation and live performance environments, providing a low-latency suite for vocal practice, pitch monitoring, and real-time effects processing.

Built entirely in Swift and Metal, Tono leverages state-of-the-art machine learning models to isolate vocals with surgical precision, allowing users to sing alongside their favorite tracks with professional-grade monitoring.

🚀 Key Features

- Neural Audio Separation

- MelBand-RoFormer (Kimberly Jensen Ed.): High-fidelity AI vocal isolation.

- Dual-Track Mixer: Independent gain control for AI-split stems (Vocals/Instrumentals).

- Raw-Import Fallback: Support for standard playback without separation processing.

- Live Monitoring & FX Engine

- Low-Latency Pipeline: Real-time microphone monitoring with optimized buffer control.

- Professional FX Chain: Integrated Gate, 3-Band EQ, Compressor, Delay, and Reverb.

- Presets & Fine Control: Toggle between curated FX presets or manual parameter adjustment.

- Performance Analysis & UI

- Real-Time Pitch Detection: Live tracking with note and cents precision.

- Reactive Visualizer: Metal-accelerated visuals with lyrics-panel and full-background modes.

- Synced Lyrics: Auto-fetch via LRCLIB with local JSON caching and manual search.

- Library Management: Drag-and-drop import, folder organization, and "Reveal in Finder" actions.

🛠️ Technology Stack

- Tono is engineered for the macOS ecosystem, utilizing low-level frameworks for maximum performance:

- Swift & SwiftUI: Core application logic and @Observable state architecture.

- AVFoundation & CoreAudio: Audio I/O routing and device/buffer management.

- AudioKit & SoundpipeAudioKit: Signal playback graphs and pitch-tap integration.

- Metal: Custom .metal shaders for GPU-accelerated audio post-processing.

- Accelerate / vDSP: High-performance FFT/STFT math and waveform analysis.

- Machine Learning: PyTorch model integration via Objective-C++ bridge (TorchModule) and Core ML compiled .mlmodelc     assets for on-device inference.

- Networking: URLSession integration with LRCLIB API for synced lyrics.

💾 Installation

1. Download the latest release from the Releases page.

2. Open the .zip and drag Tono.app to Applications.

3. Launch Tono.app.

Note: On first launch, you may need to grant Microphone and File System permissions for the app to process audio correctly.
If the app gives you a malware warning (it's not), go to Settings > Privacy and Settings > Select "allow anyway" for the app, and the app should open correctly upon future starts.

⚙️ Requirements

- OS: macOS 26+

- Architecture: Optimized for Apple Silicon (M4+). Does not support Intel Macs.

🤝 Contributing

Contributions are welcome! If you encounter a bug or have a feature request regarding the DSP chain or ML inference performance, please open an issue or submit a pull request.

Disclaimer: This app was entirely written by AI with human assistance.

AI Agents Involved in Project:

- Gemini 3.1 (UI/UX Design, Aesthetics)

- Claude Haiku 4.5 + Sonnet + Opus 4.6 (Architecture, Optimization)

- Codex 5.3 (Bug review)

Special thanks to Kimberly Jensen for their amazing vocal separation model!!~
You can check out the model itself here: https://github.com/KimberleyJensen/Mel-Band-Roformer-Vocal-Model

## License

This repository is licensed under the GNU General Public License v3.0. See [LICENSE](LICENSE).

## Third-Party Model Notice

Tono includes and uses assets derived from the `KimberleyJSN/melbandroformer` vocal separation model. That model is published under GPL-3.0 on Hugging Face, and this repository treats the combined distributed work accordingly.

Relevant project files include:

- `Tono/Services/VocalSeparator.swift`
- `Tono/Resources/MelBandRoFormer.mlmodelc`
- `scripts/convert_to_coreml.py`
- `scripts/Mel-Band-Roformer-Vocal-Model/`

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution and distribution notes.

## Source Availability

Because this repository distributes GPL-covered components, the corresponding source for the covered work should remain available alongside any distributed binaries or packaged releases.
