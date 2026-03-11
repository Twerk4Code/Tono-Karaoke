# Third-Party Notices

This project includes or derives from third-party software and model assets.

## KimberleyJSN melbandroformer

- Component: `KimberleyJSN/melbandroformer`
- Purpose: AI vocal separation model used by Tono
- Upstream page: <https://huggingface.co/KimberleyJSN/melbandroformer>
- Reported license: GPL-3.0

Tono contains code and packaged model artifacts related to this separator, including:

- `Tono/Services/VocalSeparator.swift`
- `Tono/Resources/MelBandRoFormer.mlmodelc`
- `scripts/convert_to_coreml.py`
- `scripts/Mel-Band-Roformer-Vocal-Model/`

The repository license is GPL-3.0 to align with distribution of this GPL-covered dependency and its derived packaged artifacts.

## Distribution Note

If you distribute Tono binaries, app bundles, or releases that include this model or derived converted weights, you should also make the corresponding source for the covered work available under GPL-3.0 terms.
