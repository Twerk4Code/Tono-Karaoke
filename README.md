# Tono

Tono is a macOS karaoke and vocal performance app built for singers who want less setup and more singing. Import a song, separate vocals and instrumentals on-device, and step into a performance-ready workspace with real-time control over mix, pitch, lyrics, and effects. 🎤

Whether you're rehearsing harmonies at home, dialing in a live set, or squeezing in one more run-through before showtime, Tono keeps the workflow fast, local, and singer-first. ✨

## Why Tono

- 🎚️ **Your tracks stay on your Mac.** Vocal separation happens on-device, so there is no cloud upload required.
- 🎵 **It is built for actual performance.** You can balance vocals and instrumentals, queue songs, see what is up next, and jump into a stage-friendly Gig Mode.
- 🎤 **You can shape your sound live.** Monitor your mic, add effects, tune your vocal chain, transpose key, and slow things down or speed them up on the fly.
- 📝 **Lyrics are part of the experience.** Search, assign, and display synced lyrics while you perform.
- 🔌 **It is made to stay usable in the real world.** Audio routing and device recovery are designed for practice sessions, interfaces, headphones, and changing setups.

## Features

- 🎙️ On-device vocal separation with no cloud upload required
- 🎚️ Dual-stem playback with independent Vocal and Instrumental volume controls
- ⏭️ Song queue and setlist flow with "Up Next" support
- 🌟 Gig Mode with full-screen, stage-friendly lyrics and quick controls
- 📝 Live lyrics workflow for searching, assigning, and displaying synced lyrics
- 🎯 Real-time pitch tracking for vocal feedback
- 🎧 Mic monitoring with an effects chain
- 🎹 Built-in vocal tuner controls for key, scale, amount, and speed
- 🔁 Key transpose controls from -12 to +12 semitones
- ⏱️ Playback speed controls for practice and performance
- 🌊 Waveform scrubbing and transport controls
- ✏️ Song metadata editing in-app
- 📂 Library organization with custom folders and folder cleanup
- 🔊 Improved audio routing and device recovery for more stable sessions

## System Requirements

- macOS 26.0 (Tahoe) or later
- Apple Silicon Mac
- Microphone permission for live monitoring and pitch features
- Audio files in common formats like MP3, WAV, and M4A

## Installation

### Recommended: Release Build

1. Download the latest `.zip` from [GitHub Releases](https://github.com/Twerk4Code/Tono-Karaoke/releases).
2. Unzip it and drag `Tono.app` into your `Applications` folder.
3. Open `Tono.app`.
4. If macOS blocks the app the first time, go to `System Settings > Privacy & Security`, click `Open Anyway` for Tono, then launch it again.

## Build From Source

1. Install Xcode 16.0 or newer.
2. Clone the repository:

```bash
git clone https://github.com/Twerk4Code/Tono-Karaoke.git
```

3. Open `Tono.xcodeproj` in Xcode.
4. Select the `Tono` scheme and a macOS target.
5. Build and run from Xcode.

## First Run

1. Grant microphone permission when prompted.
2. Import your first song.
3. Let Tono generate separated stems for vocals and instrumental.
4. Set your mix, key, speed, and effects.
5. Add lyrics if you want a full performance view.
6. Switch to Gig Mode when you are ready to sing.

## Quick Start

1. Import a song from the Library view.
2. Wait for stem separation to finish.
3. Open the Performance view.
4. Adjust transpose, speed, and mix until it feels right.
5. Enable mic monitoring and effects if you want to sing through Tono.
6. Add songs to the Queue for a smoother rehearsal or set flow.
7. Use Gig Mode when you want the big, stage-ready experience. 🎶

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
