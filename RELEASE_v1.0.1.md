# Tono v1.0.1

**Release Date:** March 14, 2026

## 🎵 What's New

### New Features
- **Delete Custom Folders** - Clean up your library by removing custom song folders you no longer need

## 🐛 Bug Fixes

### Audio Engine Stability
We squashed a bunch of audio crashes that were happening during device changes and system sleep. The big ones:

- **Fixed crash after sleep/wake** (-10875 error) - Added intelligent retry logic with progressive delays to give CoreAudio HAL time to stabilize
- **Fixed device switching failures** (-10851 error) - Properly reset the audio engine before switching to a new device
- **Fixed infinite recovery loops** - Engine now correctly restores the previous device if a switch fails
- **Fixed unnecessary engine cycling** - Smart detection of related audio devices (like MacBook Speakers + internal aggregate) prevents pointless restarts

### Error Detection
- Better validation of audio routes before engine start — catches broken configurations before they cause crashes
- More informative error logging for debugging audio issues

## 🔧 Technical Details

**Key Changes:**
- New `startEngineWithRetry()` with progressive backoff (300ms → 600ms → 900ms)
- New `deviceIsRelated()` helper to detect CoreAudio aggregate relationships
- `safeRestartEngine()` now supports preferred device restoration
- `setOutputDevice()` enhanced with smarter early-return logic
- Better thread safety around device property queries

**Files Modified:**
- `Services/AudioEngineManager.swift`

**Tests Passed:**
- ✅ Sleep/wake cycles
- ✅ USB audio hotplug
- ✅ MOTU ↔ built-in speaker switching
- ✅ Full-duplex mic + playback
- ✅ Mic permission flows
- ✅ Playback position sync through device changes

## 📋 Requirements

- **macOS:** 26.0 (Tahoe) or later
- **Hardware:** Apple Silicon (M4+) — Intel Macs not supported
- **Xcode:** 16.0+
- **Swift:** 6.0 (strict concurrency)
- **AudioKit:** 5.6.2+

## 📝 Known Issues

- Device IDs can shift between app restarts (macOS behavior)
- Some third-party audio interfaces may not report related devices correctly
- Full-duplex operation requires compatible input/output hardware

## ⚠️ Important

This release requires **macOS 26.0 (Tahoe) or later** and **Apple Silicon M4+** — Intel Macs are not supported.

## 🙏 Thanks

Thanks to everyone who reported audio issues and helped us track down these edge cases. This release is way more stable.

---

**What's Next?** Keep an eye on the main branch for improvements to vocal separation and UI polish.

**Found a bug?** [Open an issue](https://github.com/yourusername/tono/issues) with your audio setup details.
