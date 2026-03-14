# Tono - macOS Karaoke App

**Language:** Swift 6.0 (strict concurrency) | **UI:** SwiftUI | **Platform:** macOS 26.0+ ARM64
**Purpose:** Real-time vocal stem separation + karaoke performance tool
**ML Model:** MelBandRoFormer (LibTorch on GPU) | **Audio Engine:** AudioKit 5.6.2+

---

## Quick Start

### Build Commands

**Generate Xcode project:**
```bash
./xcodegen
# or: xcodegen generate
```

**Build from command line:**
```bash
swift build -c release
# or via Xcode after generating .xcodeproj
open Tono.xcodeproj
```

**Build & run directly:**
```bash
swift run Tono
```

**Requirements:** Xcode 16+, Swift 6.0, macOS 26.0+ (ARM64), HomeBrew `libomp`

---

## Environment & Setup

### Prerequisites
- **Xcode 16+** with Swift 6.0
- **macOS 26.0+** (ARM64 only)
- **HomeBrew** libomp: `brew install libomp` (required for LibTorch linking)
- **LibTorch** (arm64): Pre-built at `./libtorch/` after extraction from `libtorch-macos-arm64.zip`

### Automatic Post-Build Setup
- LibTorch dylibs are **automatically embedded** into the app bundle via the XcodeGen post-build script in `project.yml`
- No need to run `bundle_dylibs.sh` manually unless you modify LibTorch or need custom code signing
- Verify embedding: `ls -la Tono.app/Contents/Frameworks/ | grep libtorch`

---

## Development Workflow

### Typical Dev Loop
1. **Edit code** in `Tono/` directory
2. **Regenerate project** (if adding/removing files): `./xcodegen`
3. **Build & run**: `swift run Tono` or use Xcode (Cmd+R)
4. **Test audio features**: Use Console.app to view audio/CoreAudio logs
5. **Debug memory**: Use Instruments → Allocations when testing stem separation

### IDE Setup
- Open Xcode: `open Tono.xcodeproj` (after running `./xcodegen`)
- Swift Package Plugins may prompt on first build (accept to generate .xcodeproj)

### Window Configuration
Default app window:
```swift
.windowStyle(.hiddenTitleBar)              // Frameless window with integrated toolbar
.windowResizability(.contentSize)          // Resizable by content
.defaultSize(width: 1100, height: 740)     // Initial window dimensions
```

Settings window accessed via macOS Settings scene (Cmd+,)

---

## Quick File Map

### Views & UI Components
| Component | File Path | Purpose | LoC |
|-----------|-----------|---------|-----|
| **Entry** | TonoApp.swift | App root, window setup (hiddenTitleBar, 1100x740 default) | 50 |
| **Root View** | ContentView.swift | NavigationSplitView root | 40 |
| **Playback UI** | PerformanceView.swift | Main karaoke interface | 300+ |
| **Sidebar** | LibraryView.swift | Song list, folder organization, selection | 150+ |
| **Song Card** | SongCard.swift | Individual song cell in library | 100+ |
| **Settings** | SettingsView.swift | Preferences UI | 200+ |
| **Menu Bar** | MenuBarExtraView.swift | Menu bar extra interface | 50+ |
| **Lyrics Display** | LyricsDisplay.swift | Synced lyrics with LRC support, headphone warning | 1091 |
| **Waveform** | WaveformGenerator.swift | Waveform visualization | 72 |
| **Visualizer BG** | ReactiveVisualizerBackgroundView.swift | Global background visualizer | 150+ |
| **Effects Panel** | EffectsPanel.swift | Effects chain UI controls | 360 |

### ViewModels & State
| Component | File Path | Purpose | LoC |
|-----------|-----------|---------|-----|
| **Global State** | AppState.swift | All service initialization, state flow, crash guard | 600+ |
| **Player VM** | PlayerViewModel.swift | Playback control logic | 200+ |
| **Pitch VM** | PitchViewModel.swift | Pitch tracking state | 100+ |
| **Effects VM** | EffectsViewModel.swift | Effects chain state | 150+ |
| **Library VM** | LibraryViewModel.swift | Song library management | 200+ |

### Audio Services
| Component | File Path | Purpose | LoC |
|-----------|-----------|---------|-----|
| **Audio Engine** | AudioEngineManager.swift | Dual-stem playback, mixing, mic monitoring | 1400+ |
| **Vocal Separation** | VocalSeparator.swift | LibTorch ML inference with overlap-add | 375 |
| **Device Manager** | AudioDeviceManager.swift | CoreAudio device enumeration, routing | 279 |
| **Effects Chain** | EffectsProcessor.swift | VST-style effects (gate, EQ, comp, reverb, delay) | 418 |
| **GPU Audio** | MetalAudioProcessor.swift | Metal-accelerated overlap-add | 352 |
| **Pitch Tracker** | PitchTracker.swift | Real-time pitch detection | 58 |
| **PyTorch Bridge** | TorchModule.h/.mm | Objective-C++ LibTorch wrapper | 200+ |
| **Visualizer Analyzer** | PlaybackVisualizerAnalyzer.swift | FFT analysis for visualizer | 200+ |

### Content & Data Services
| Component | File Path | Purpose | LoC |
|-----------|-----------|---------|-----|
| **Lyrics Service** | LyricsService.swift | LRCLIB fetching, parsing, caching | 139 |
| **Lyrics Cache** | LyricsCache.swift | Lyrics file storage management | 100+ |
| **Song Library** | SongLibrary.swift | Song DB, folder organization, JSON persistence | 300+ |
| **Stem Store** | StemFileStore.swift | Stem file storage and retrieval | 150+ |
| **Upload Store** | UploadFileStore.swift | Original upload file management | 100+ |
| **Metadata Extractor** | MetadataExtractor.swift | ID3 tag extraction (title, artist, art, duration) | 150+ |
| **App Settings** | AppSettings.swift | User preferences persistence | 200+ |

### Models
| Component | File Path | Purpose | LoC |
|-----------|-----------|---------|-----|
| **Song** | Song.swift | Song model with stems, lyrics, folder assignment | 100+ |
| **Library Folder** | LibraryFolder.swift | Folder organization model | 50+ |
| **Colors** | TonoColors.swift | App color palette | 50+ |

---

## Architecture Layers

```
┌─────────────────────────────────────────┐
│         SwiftUI Views                   │ (11 files: ContentView, PerformanceView, 
│                                         │  LibraryView, SettingsView, LyricsDisplay,
│                                         │  MenuBarExtraView, etc.)
├─────────────────────────────────────────┤
│    ViewModels (@Observable)             │ (5 files: AppState, PlayerViewModel,
│                                         │  PitchViewModel, EffectsViewModel,
│                                         │  LibraryViewModel)
├─────────────────────────────────────────┤
│       Service Layer                     │
│  ┌──────────────────────────────────┐  │
│  │ Audio:                           │  │
│  │ - AudioEngineManager (player)    │  │
│  │ - VocalSeparator (ML inference)  │  │
│  │ - AudioDeviceManager (CoreAudio) │  │
│  │ - MetalAudioProcessor (GPU)      │  │
│  │ - EffectsProcessor (effects)     │  │
│  │ - PitchTracker (analysis)        │  │
│  │ - PlaybackVisualizerAnalyzer     │  │
│  │                                  │  │
│  │ Content:                         │  │
│  │ - LyricsService (LRCLIB fetch)   │  │
│  │ - LyricsCache (lyrics storage)   │  │
│  │ - MetadataExtractor (ID3 tags)   │  │
│  │ - SongLibrary (DB/folders/JSON)  │  │
│  │ - StemFileStore (stem mgmt)      │  │
│  │ - UploadFileStore (upload mgmt)  │  │
│  │                                  │  │
│  │ System:                          │  │
│  │ - AppSettings (preferences)      │  │
│  └──────────────────────────────────┘  │
├─────────────────────────────────────────┤
│       Low-Level Audio Pipeline          │
│  ┌──────────────────────────────────┐  │
│  │ Input: File decode (44.1kHz)     │  │
│  │ ↓ VocalSeparator (LibTorch)      │  │
│  │ ↓ MetalAudioProcessor (GPU)      │  │
│  │ ↓ AudioEngineManager mixer       │  │
│  │ ↓ PlaybackVisualizerAnalyzer     │  │
│  │ Output: Device playback          │  │
│  └──────────────────────────────────┘  │
├─────────────────────────────────────────┤
│  Native: CoreAudio, AudioKit, Metal     │
└─────────────────────────────────────────┘
```

---

## Data Models

### Song Model
```swift
struct Song: Codable, Identifiable {
    let id: UUID                          // Unique song identifier
    var title: String                     // Display title (from ID3 or filename)
    var artist: String                    // Artist name (from ID3 or "Unknown Artist")
    let originalURL: URL                  // Original file location (may not exist)
    var storedUploadURL: URL?            // Copied file in ~/Library/Application Support/Tono/Uploads/
    var vocalURL: URL?                   // Path to separated vocal stem
    var instrumentalURL: URL?            // Path to separated instrumental stem
    var lrcURL: URL?                     // Path to cached lyrics file
    var albumArt: NSImage?               // Album artwork from ID3 tags
    var duration: TimeInterval           // Total playback duration
    var importMode: ImportMode           // .separated or .raw
    var folderID: UUID?                  // Optional folder assignment
    var dateAdded: Date                  // Import timestamp
    
    var playbackURL: URL {               // Helper: preferred playback source
        storedUploadURL ?? originalURL
    }
}

enum ImportMode: String, Codable {
    case separated  // Full vocal separation via RoFormer
    case raw        // Original file, no stem processing
}
```

### LibraryFolder Model
```swift
struct LibraryFolder: Codable, Identifiable {
    let id: UUID                         // Unique folder identifier
    var name: String                     // Display name
    var dateCreated: Date                // Creation timestamp
}
```

### Library Storage Format
```swift
struct StoragePayload: Codable {
    var songs: [Song]
    var folders: [LibraryFolder]
}
// Persisted to: ~/Library/Application Support/Tono/library.json
```

---

## Component Sections for Bug Review

### 1. **State Management** (AppState.swift)
- **Responsibility:** Initialize all services, manage app lifecycle, global state, visualizer crash guard
- **Key Properties:** `audioEngine`, `vocalSeparator`, `lyrics`, `effects`, `playbackSettings`, `playbackVisualizer`
- **Key Features:**
  - Visualizer crash guard (4-second activation window)
  - Stability migration system
  - Device persistence and restoration after configuration changes
  - Automatic lyrics fetching via LRCLIB on import
  - Re-import optimization (reuses cached stems when same file is imported again)
- **Critical Path:** App startup → service init → device restoration → ready for playback
- **Common Issues:**
  - Service dependency initialization order (LibTorch must load before separator use)
  - Lifecycle mismatches (UI updates before service ready)
  - Memory leaks in @Observable bindings
  - Microphone permission must be requested before accessing inputNode

### 2. **Audio Playback Engine** (AudioEngineManager.swift)
**Core responsibility:** Manage AVAudioEngine graph with dual-stem mixing, mic monitoring, visualizer analysis
- **Architecture:**
  ```
  vocalPlayer ──→ vocalMixer ──┐
  instrumentalPlayer ──→ instrumentalMixer ──┐
                                              ├→ mainMixer → visualizerTapMixer → outputDevice
  micInput → micMonoMixer → micEffects → micMonitorMixer ──┘
  ```
  **Key Nodes:**
  - `micMonoMixer` - Forces mono input (critical for single-channel devices like MOTU M2 left-only input)
  - `visualizerTapMixer` - Dedicated tap point for visualizer analysis (isolated from main bus)
  - `mainMixer` - Final mix point before output
  - Transition mute mechanism - Prevents clicks during device changes
- **Thread Safety:** Uses DispatchQueue for player operations (@MainActor for UI)
- **Critical Methods:**
  - `loadAudio()` - File decode to stereo float at 44.1kHz
  - `loadStems()` - Attach vocal/instrumental buses to engine (separated mode)
  - `loadRawSong()` - Load original file without stems (raw mode)
  - `updateGains()` - Volume control for vocal/instrumental/mic
  - `startPlayback()` / `stopPlayback()` - Engine state management
  - `setInputDevice()` / `setOutputDevice()` - Device routing with pending queue
  - `setupMicrophone()` - Mic path initialization with effects chain
  - `refreshVisualizerTapState()` - Attach/detach visualizer tap
- **Device Management:**
  - Pending device mechanism queues device ID before engine starts
  - `onEngineRestarted` callback re-applies saved device selections after configuration changes
  - Prevents kAudioObjectUnknown errors by queuing instead of accessing inputNode prematurely
- **Common Bugs:**
  - Thread violations (CoreAudio ops off main thread)
  - Attach/detach node sequencing (must stop engine before detach)
  - Memory not freed on node removal
  - Sample rate mismatches between buses
  - Device hot-swap during playback

### 3. **Vocal Separation (ML)** (VocalSeparator.swift)
**Responsibility:** Load LibTorch model, split audio into vocal/instrumental
- **ML Pipeline:**
  1. File → decode to 44.1kHz Float32 mono
  2. Chunk into ~3.5s windows (overlap-add windowing)
  3. Reflection padding (prevent edge artifacts)
  4. LibTorch inference (TorchModule.mm bridge)
  5. Reconstruct audio with 50% overlap
- **Key Methods:**
  - `loadModel()` - Load MelBandRoFormer.mlmodelc via TorchModule
  - `separateAudio()` - Core async inference
  - `processChunk()` - Single chunk inference with windowing
- **Common Bugs:**
  - LibTorch not found (bundle_dylibs.sh not run)
  - Out-of-memory on large files (chunks are 256KB+)
  - Audio clipping post-inference (gain scaling issues)
  - Model precision mismatches (expect float32)

### 4. **Effects & Processing** (EffectsProcessor.swift, MetalAudioProcessor.swift)
- **EffectsProcessor:** Gate, EQ, Compression, Reverb (AudioKit nodes), Delay
  - **Chain Order:** Gate → EQ → Compression → Reverb → Delay
  - **Threading:** Effects chain on audio thread, parameter updates from main
- **MetalAudioProcessor:** GPU overlap-add reconstruction
  - **Compute Shaders:** Windowing + FFT overlap logic
  - **Common Bugs:** Metal buffer alignment, GPU memory leaks, shader compilation
- **Common Issues:**
  - Effect parameter changes cause audio pops (need ramping, not step changes)
  - Reverb tail not properly flushed on stop
  - Compression ratio/threshold inversions
  - Metal shader errors on older macOS versions

### 5. **Device Management** (AudioDeviceManager.swift)
**Responsibility:** Enumerate audio inputs/outputs, handle device changes, UID ↔ DeviceID mapping
- **Key Methods:**
  - `listInputDevices()` / `listOutputDevices()`
  - `deviceID(forUID:)` - Convert UID string to CoreAudio DeviceID
  - Device change listener (AudioObjectPropertyListener)
- **Startup Sequence:**
  1. Load saved device UID from AppSettings
  2. Convert UID to DeviceID
  3. Queue device ID in AudioEngineManager (`setPendingInputDevice`)
  4. Start engine
  5. Apply saved output device after engine is running
  6. Mic path applies queued input device when `setupMicrophone()` runs
- **Device Restoration:**
  - `onEngineRestarted` callback in AppState re-applies device selections
  - Ensures MOTU M2 or other non-default devices persist after sample-rate changes
- **Common Bugs:**
  - Stale device refs after device disconnect
  - Permission denied errors (check audio input permission before accessing mic)
  - Default device fallback logic
  - Sample rate conversion on device mismatch
  - Accessing inputNode before engine starts triggers kAudioObjectUnknown cascade

### 6. **Pitch Tracking** (PitchTracker.swift)
**Responsibility:** Real-time pitch detection for feedback display
- **Algorithm:** Likely FFT-based or autocorrelation
- **Common Bugs:**
  - Silence detection false positives
  - Octave jumps in pitch contour
  - Lag between audio and displayed pitch
  - CPU spikes during analysis

### 7. **Lyrics & Display** (LyricsService.swift, LyricsDisplay.swift, LyricsCache.swift)
**Responsibility:** Fetch lyrics from LRCLIB, parse LRC files, sync with playback, display with headphone warning
- **Architecture:**
  - `LyricsService` - LRCLIB API integration, automatic fetching on import
  - `LyricsCache` - File storage management in `~/Library/Application Support/Tono/Lyrics/`
  - `LyricsDisplay` - SwiftUI view with sync, styling, headphone safety warning
  - Background task management in AppState (`lyricsFetchTasks`)
- **Key Methods:**
  - `fetchAndCache()` - Async stream that fetches from LRCLIB and caches
  - `loadLyrics(filename)` - Parse LRC/SRT/VTT formats
  - `getLyricsForTime()` - O(1) lookup by playback position
  - `assignLyrics(to:)` - Manual lyrics assignment after search
  - `clearLyrics(for:)` - Remove lyrics association
- **Workflow:**
  1. Import song → `beginLyricsFetch()` starts background task
  2. LRCLIB search by title + artist
  3. Cache LRC file with songID
  4. Update song.lrcURL in library
  5. Keep selectedSong in sync for immediate display
- **Common Bugs:**
  - Timing sync drift (accumulates with playback speed changes)
  - Unicode/encoding issues in LRC files
  - Missing file handling
  - Lyric display cutoff at view boundaries
  - Search focus state conflicts

### 8. **File Storage & Persistence** (SongLibrary.swift, StemFileStore.swift, UploadFileStore.swift, LyricsCache.swift)
**Responsibility:** Manage song DB with folder organization, cache separated stems, handle imports, lyrics storage
- **Key Paths:**
  - User songs: `~/Library/Application Support/Tono/library.json`
  - Original uploads: `~/Library/Application Support/Tono/Uploads/`
  - Stem cache: `~/Library/Application Support/Tono/Stems/`
  - Lyrics cache: `~/Library/Application Support/Tono/Lyrics/`
  - Settings: `AppSettings` (JSON persistence)
- **Folder Organization:**
  - `LibraryFolder` model with UUID and name
  - Songs can be assigned to folders via `folderID`
  - Folder CRUD operations: `addFolder()`, `deleteFolder()`, `assignSong()`
  - Folders sorted alphabetically
- **Re-import Optimization:**
  - `existingSeparatedStems()` checks if source file was previously separated
  - Copies cached stems instead of re-running ML inference
  - Significant performance improvement for re-importing the same file
- **Common Bugs:**
  - Stale cache after file updates
  - Disk space exhaustion (stems are large: ~2x original file)
  - Path encoding issues (unicode filenames)
  - Race conditions on concurrent file access
  - Orphaned files when library.json becomes inconsistent

### 9. **Visualizer System** (PlaybackVisualizerAnalyzer.swift, ReactiveVisualizerBackgroundView.swift)
**Responsibility:** FFT-based playback visualization with crash protection, style options, placement modes
- **Components:**
  - `PlaybackVisualizerAnalyzer` - FFT analysis (512-point) with intensity control
  - `ReactiveVisualizerBackgroundView` - SwiftUI rendering layer
  - Dedicated `visualizerTapMixer` in AudioEngineManager for isolated tap
- **Crash Guard System:**
  - 4-second activation window armed when visualizer is enabled
  - If app crashes during window, visualizer auto-disabled on next launch
  - Stability migration flag for updates
  - UserDefaults keys: `com.tono.visualizer.crash_guard_active`, `com.tono.visualizer_stability_migration_v1`
- **Customization Options:**
  - **Placement:** `.globalBackground` (full-screen) or `.lyricsPane` (overlay on lyrics)
  - **Style:** Multiple styles including `.appleMovie` mode
  - **Intensity:** 0.15–0.8 (controls amplitude scaling)
  - **Readability Scrim:** 0.20–0.85 (background darkening for text readability)
- **Performance:**
  - GPU-accelerated rendering
  - Tap attach/detach managed by `refreshVisualizerTapState()`
  - Disabled state completely removes tap to save CPU/GPU
- **Common Issues:**
  - Metal shader compilation on older macOS versions
  - GPU memory leaks if tap not properly detached
  - Crash loop if guard mechanism disabled manually

### 10. **Metadata Extraction** (MetadataExtractor.swift)
**Responsibility:** Extract ID3 tags and metadata from audio files
- **Extracted Data:**
  - Title (ID3 tag or filename fallback)
  - Artist (ID3 tag or "Unknown Artist" fallback)
  - Album art (NSImage from embedded artwork)
  - Duration (audio file length)
- **Integration:**
  - Called during import in `importSong(from:mode:)`
  - Metadata attached to Song model before library insertion
- **Common Issues:**
  - Missing tags in some file formats (M4A vs MP3)
  - Album art format conversion failures
  - Duration calculation inaccuracies for VBR files

### 11. **UI Components** (Views/Components/)
| File | Responsibility | Common Bugs |
|------|-----------------|------------|
| TransportControls | Play/pause/seek buttons | Seek during import crashes engine |
| MixerPanel | Dual-stem volume sliders | Slider lag, DB scaling issues |
| EffectsPanel | Effects chain UI controls | Parameter out-of-sync with audio |
| WaveformView | Waveform visualization | Rendering lag on long songs |
| PitchDisplay | Pitch visualization | Vertical scroll cutoff |
| LyricsDisplay | Lyric text display, sync, headphone warning | Font size cutoff, line wrapping, search focus |
| SongCard | Individual song cell in library | Album art loading delays |
| MenuBarExtraView | Menu bar extra dropdown | State sync with main window |

---

## Common Patterns & Conventions

### Async Operations
- Use `Task { @MainActor in ... }` for UI updates from background work
- Services use DispatchQueue for audio thread ops
- File I/O is async in SongLibrary

### Thread Safety
- **Main Thread:** All SwiftUI updates
- **Audio Thread:** CoreAudio callbacks, effects processing
- **Background:** File I/O, ML inference (DispatchQueue.global)
- **Use:** @MainActor, DispatchQueue, Task boundaries

### Error Handling
- AppState shows toast errors via `currentError` binding (not `errorMessage`)
- Audio errors typically logged, not surfaced to user
- File errors shown in UI (missing file, permission denied)
- Import errors shown via `importError` property

### Memory Management
- Audio nodes: Detach before dealloc
- LibTorch: Keep TorchModule singleton
- Listeners: Remove device change listeners on deinit

---

## Critical Flow: Song Playback

```
User taps song in LibraryView
  ↓
LibraryViewModel.selectSong(song)
  ↓
AppState.selectSong(song)
  1. Stop pitch tracking (prevents CoreAudio deadlock)
  2. Stop audio engine and wait
  3. Check import mode: .raw or .separated
  
  FOR RAW MODE:
    a. Find playback file (storedUploadURL or originalURL)
    b. Verify file exists
    c. Call AudioEngineManager.loadRawSong(url:)
  
  FOR SEPARATED MODE:
    a. Check if stems cached in StemFileStore
    b. If not, call VocalSeparator.separateAudio() (async, ~1-5 min, with re-import optimization)
    c. Verify stem files exist on disk
    d. Call AudioEngineManager.loadStems(vocalURL:, instrumentalURL:)
  
  4. Restart engine if stopped unexpectedly
  5. Re-attach pitch tracker if it was running before switch
  6. Load lyrics from LyricsCache if lrcURL exists
  ↓
PerformanceView updates:
  - Waveform rendered via PlayerViewModel.loadWaveform()
  - Lyrics synced via LyricsDisplay
  - Visualizer analyzer configured
  - Ready for playback
  ↓
User presses play
  ↓
AudioEngineManager.startPlayback()
  1. Start AVAudioEngine
  2. Schedule vocal + instrumental nodes (or raw player)
  3. Monitor pitch in PitchTracker (if mic enabled)
  4. Feed visualizer analyzer tap
  5. Update UI on timer (position, lyrics sync)
  ↓
On stop: AudioEngineManager.stopPlayback()
  - Persist playback position in AppSettings
  - Keep engine running for instant re-play
```

---

## Known Gotchas & Common Issues

| Issue | Root Cause | Fix |
|-------|-----------|-----|
| App crashes on import | LibTorch not bundled (bundle_dylibs.sh) | Run post-build script, verify rpath |
| No audio output | Device enumeration fails / mismatch sample rate | Check AudioDeviceManager logs |
| Vocals/instrumentals swapped | VocalSeparator output order (check TorchModule.mm) | Verify model output tensor order |
| Lyrics sync drifts | Playback sample rate mismatch (44.1 vs 48kHz) | Force all audio to 44.1kHz in decoder |
| Pitch tracking lags | Analysis window too large or sync issue | Check PitchTracker buffer window size |
| Memory grows unbounded | Metal buffers or effect reverb tail not freed | Monitor via Instruments; check effect cleanup |
| Thread crashes (EXC_BAD_ACCESS) | UI update off main thread or audio node access | Use @MainActor, DispatchQueue boundaries |
| File import hangs | Large file decode blocking UI | Ensure file I/O is async (DispatchQueue.global) |
| Visualizer crashes app | Metal shader error or GPU memory leak | Check crash guard; disable visualizer in Settings |
| Microphone permission denied | Permission not requested before inputNode access | Call requestMicrophonePermission() early |
| Device not restored after hotplug | onEngineRestarted callback missing | Verify callback re-applies saved device UID |
| Stem files missing after import | Re-import optimization copy failed | Check StemFileStore write permissions |
| MOTU M2 left channel only | micMonoMixer not in audio graph | Verify micMonoMixer forces stereo output |
| Lyrics not fetching | LRCLIB API failure or rate limit | Check LyricsService error logs; graceful degradation |
| Folder assignments lost | library.json corruption | Call sanitizeFolderAssignments() on load |
| Raw mode has no vocals control | Expected behavior - raw file has no stems | UI should hide vocal/instrumental sliders in raw mode |

---

## Testing Checklist (Bug Prevention)

### Audio Pipeline
- [ ] Vocal/instrumental separation produces correct output (not swapped)
- [ ] Volume sliders don't cause distortion (gain scaling)
- [ ] Playback stops cleanly (no hanging audio)
- [ ] Device hotplug doesn't crash (listener properly removes)
- [ ] Sample rate conversions don't introduce artifacts
- [ ] Raw mode plays original file without stem controls
- [ ] Mic monitoring works with mono input devices (MOTU M2)
- [ ] Buffer size changes apply correctly without crackling

### Performance
- [ ] Separation completes in reasonable time (~2-5 min for 3-4 min song)
- [ ] UI remains responsive during separation
- [ ] Memory stays bounded (no leaks in Instruments)
- [ ] GPU usage reasonable (Metal shader efficient)
- [ ] Re-import optimization reuses cached stems correctly

### UI/UX
- [ ] Lyrics sync to playback within <100ms
- [ ] Pitch display updates smoothly
- [ ] Waveform renders without lag
- [ ] Seek bar dragging works without crashes
- [ ] Volume sliders update in real-time
- [ ] Visualizer crash guard protects against infinite crash loops
- [ ] Folder organization persists across launches
- [ ] Headphone warning displays when appropriate

### File Handling
- [ ] Import large file (>500MB) without crashing
- [ ] Stem cache saves/loads correctly
- [ ] Unicode filenames handled
- [ ] Disk space warning on low storage
- [ ] Orphaned temp files cleaned up
- [ ] Metadata extraction works for MP3, M4A, WAV
- [ ] Album art displays correctly

### Edge Cases
- [ ] Very short song (<10s) separates correctly
- [ ] Very long song (>10min) doesn't OOM
- [ ] No input devices crashes gracefully
- [ ] Missing lyrics file shows message, doesn't crash
- [ ] Closed file during playback doesn't crash
- [ ] Device change during playback recovers smoothly
- [ ] Visualizer disabled state completely removes tap
- [ ] Lyrics fetching failure degrades gracefully

### Visualizer
- [ ] Crash guard activates on enable (4-second window)
- [ ] Crash recovery disables visualizer on next launch
- [ ] Placement modes work (globalBackground, lyricsPane)
- [ ] Style changes apply without restart
- [ ] Intensity and readability scrim controls work
- [ ] Visualizer tap properly detaches when disabled

### Device Management
- [ ] Saved devices restore after app restart
- [ ] Saved devices restore after configuration change
- [ ] Pending device mechanism prevents kAudioObjectUnknown errors
- [ ] Microphone permission requested before inputNode access

---

## Key External Dependencies

- **AudioKit 5.6.2+** - Real-time audio engine
- **SoundpipeAudioKit 5.6.2+** - DSP effects library
- **LibTorch (arm64)** - PyTorch ML inference (post-build bundled)
- **Metal** - GPU acceleration (macOS native)
- **CoreAudio** - Low-level device management
- **AVFoundation** - Audio codec support

---

## Build & Deployment

**Build System:** Swift Package Manager + XcodeGen

**Key Scripts:**
- `bundle_dylibs.sh` - Embed LibTorch libs, fix rpath
- `bundle_and_sign.sh` - Final code signing for distribution
- `convert_to_coreml.py` - (if using Core ML instead of LibTorch)

**Post-Build:** LibTorch dylibs are automatically embedded by XcodeGen's post-build script (see `project.yml` lines 59-112).
If you modify LibTorch path or need custom code signing, use `scripts/bundle_dylibs.sh` and `scripts/bundle_and_sign.sh` manually.

---

## Quick Debug Tips

**LibTorch not found:**
```bash
# Check if dylibs embedded in app
ls -la Tono.app/Contents/Frameworks/
# Check rpath
otool -l Tono.app/Contents/MacOS/Tono | grep "LC_RPATH"
```

**Audio engine errors:**
- Check Console.app for audio errors
- Verify device is connected: `AudioDeviceManager.listOutputDevices()`
- Check AVAudioSession category matches use case

**Memory leaks:**
- Use Instruments → Allocations to track Metal buffers
- Ensure effect nodes detach on deinit
- Check Audio Units for stale references

**Pitch tracking off:**
- Verify input device level is adequate
- Check sample rate (must be 44.1kHz)
- Test with known pitch to isolate algorithm issue

---

## Section Reference for Quick Navigation

When reviewing bugs:
1. **Crash at startup** → Check [State Management](#1-state-management)
2. **No audio** → Check [Audio Playback Engine](#2-audio-playback-engine) + [Device Management](#5-device-management)
3. **Vocal/instrumental wrong** → Check [Vocal Separation](#3-vocal-separation)
4. **Audio glitches** → Check [Effects & Processing](#4-effects--processing)
5. **File/import issues** → Check [File Storage](#8-file-storage--persistence)
6. **UI crashes** → Check [State Management](#1-state-management) + component in [UI Components](#11-ui-components)
7. **Sync drift** → Check [Critical Flow](#critical-flow-song-playback) + [Lyrics & Display](#7-lyrics--display)
8. **Visualizer crashes** → Check [Visualizer System](#9-visualizer-system)
9. **Device not restored** → Check [Device Management](#5-device-management) + [Audio Playback Engine](#2-audio-playback-engine)
10. **Lyrics not loading** → Check [Lyrics & Display](#7-lyrics--display) + [File Storage](#8-file-storage--persistence)
11. **Metadata missing** → Check [Metadata Extraction](#10-metadata-extraction)

---

**Last Updated:** 2026-03-14 | **Total App LoC:** ~11,000+ (approximate) | **Files:** 50+
