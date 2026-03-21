# Monitoring Routing Snapshot (2026-03-18)

This snapshot captures the known-good stability fix for live mic monitoring.

## Scope
- File: `Tono/Services/AudioEngineManager.swift`
- Primary function: `initializeMicInput(onReady:)`

## Known-Good Invariants
1. Mic graph mutation must happen only while engine is stopped.
2. Mic initialization is single-flight (`isInitializingMicInput`) and coalesces callbacks.
3. Rebuild starts from a clean baseline:
- clear mic nodes
- reset `mainMixer` inputs
- re-add only stem mixers first
4. Startup mic graph is constrained:
- `mic -> mono mixer -> effects (including fixed tuner stage) -> monitor mixer -> mainMixer`
- tuner is a static node inside `EffectsProcessor` (never attached/detached on a live graph)
- graph is only rebuilt while engine is stopped (no live-chain mutation)
- monitor branch includes a post-FX vocal bus with independent L/R gains
5. Start engine via retry path (`startEngineWithRetry`) and only then handle pending input switching.
6. `setInputDevice` defers while mic initialization is active.
7. Mic-path routing stays fixed to monitoring/effects only; key transposition remains playback-only.

## Output Routing Guard
- `setOutputDevice(_:)` must not force-restore the previous output device when the user requested `System Default` and switching fails.
- Recovery in that case should use neutral recovery (`preferringOutputDevice: nil`) to avoid restart loops pinned to old hardware.

## Failure Signatures This Fix Avoids
- AVAudioEngine assertion:
  - `required condition is false: false == isInputConnToConverter`
- Route churn / restart loop:
  - repeated `safeRestart(pre/post)`
  - repeated `setOutputDevice error: -10851 ... falling back`
  - repeated `setInputDevice: mic path not active — device ID saved for later`
- Invalid route state:
  - `outputDevice=0 outputSR=0 outputCh=0`

## Regression Checklist
1. Monitoring on with MOTU mic input and MacBook speakers output (system default) must not crash.
2. Voice must be audible with monitor enabled.
3. Switching output device must not cause repeated safe restart spam.
4. No `isInputConnToConverter` assertion.

## Note
If this routing changes again, re-run the regression checklist above and capture logs around `initializeMicInput(pre-start/post-start)`.
