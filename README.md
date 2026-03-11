# Tono

Tono is a macOS karaoke and vocal performance app. It imports songs, separates vocals from instrumentals on-device, and provides dual-stem playback, mic monitoring, effects, and pitch tracking.

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
