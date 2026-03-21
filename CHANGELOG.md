# Changelog - Tono v1.0.1

## [1.0.1] - 2026-03-14

### Features
- **Delete Custom Folders**: You can now remove custom song folders that you no longer need. Just right-click a folder in the library and hit delete. Clean up your organization without hassle.

### What's Fixed

#### Audio Engine Got Way More Stable

- **Engine No Longer Crashes After Sleep/Wake**
  - The audio engine was crashing with error -10875 when your Mac woke up from sleep or you plugged/unplugged audio devices. Turns out CoreAudio's HAL needs a little patience during transitions. Added progressive retry logic (300ms, 600ms, 900ms) that gives the HAL time to catch up before we try again.
  - This applies to mic initialization and config-change recovery too.

- **Device Switching Actually Works Now**
  - Switching output devices (like from MOTU to MacBook speakers) was failing with error -10851. The issue was that we weren't properly releasing the old device before setting the new one. Added a full engine reset before attempting the switch, which fixed the whole thing. Input device handling was already doing this right, so we just brought output in line.

- **No More Infinite Recovery Loops**
  - When a device switch failed, we'd try to recover but sometimes end up in a state where the audio engine thought there was no valid device (device=0, SR=0), causing -10875 on every restart attempt. Now we actually save the previous device and restore it properly if the switch goes sideways.

- **Stopped Unnecessary Engine Cycling When Using Built-in Audio**
  - Here's a quirky one: when your mic is active, macOS + AVAudioEngine create a hidden aggregate device that combines your mic and speakers into a single full-duplex unit. If you had "MacBook Speakers" saved as your preferred output but the engine was running this aggregate, we'd try to switch to just the speakers device, and the HAL would reject it with -10851.
  - Now we're smart about it — if you're selecting a device that's already covered by your current aggregate, we just skip the switch. Feels seamless now.

#### Better Error Detection

- Output device validation is way more robust now. Instead of silently accepting a broken route (device=0, no sample rate), we actually tell you when something's wrong. This caught a whole class of bugs that were hiding in plain sight.

### Under the Hood

- CoreAudio error codes are now logged with more context so debugging is actually possible
- Audio thread safety got another pass — device queries happen on the right threads
- Cleaned up some stale device references that could stick around after recovery
- Added a ton of comments explaining how CoreAudio device IDs and aggregate devices actually work (because it's weird and undocumented)

### What We Tested

- ✅ Wake from sleep without crashing (the big one)
- ✅ Plugging/unplugging USB audio interfaces
- ✅ Switching between MOTU and built-in speakers
- ✅ Explicitly selecting "MacBook Speakers" with mic active
- ✅ Falling back to system default when a device goes missing
- ✅ Full-duplex audio (mic + playback) on aggregate devices
- ✅ Mic permission flows
- ✅ Playback position sync through device changes

### Files Changed

- `Services/AudioEngineManager.swift` — Most of the work happened here
  - New `startEngineWithRetry()` method handles the -10875 backoff retry
  - New `deviceIsRelated()` method detects aggregate device relationships
  - `safeRestartEngine()` now takes an optional preferred device for recovery
  - `setOutputDevice()` is way smarter about when to actually switch
  - `recoverAfterOutputRoutingFailure()` now restores the previous device

### What's Not in This Release

- Intel Mac support (Apple Silicon M4+ only)
- Folder deletion is a nice-to-have, not a critical fix
- We didn't touch the vocal separation or UI (those were solid)

### Heads Up

- Device IDs can change between app restarts (macOS thing, not our problem)
- Some odd third-party audio interfaces might not report their related devices properly (file a bug if you hit this)
- If you're running both mic and playback, the engine will create an aggregate device — this is expected and good

---

**Requirements:**
- **macOS:** 26.0 (Tahoe) or later
- **Hardware:** Apple Silicon (M4+) — Intel Macs not supported
- **Xcode:** 16.0+
- **Swift:** 6.0 (strict concurrency)

**Status:** Tested and stable on Apple Silicon

Big thanks to everyone who reported the audio issues. This version is way more reliable.
