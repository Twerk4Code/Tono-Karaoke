import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var cachedBufferSizeOptions: [UInt32] = [64, 128, 256, 480, 512, 1024]
    @State private var cachedOutputSampleRate: Double = 48000.0

    var body: some View {
        TabView {
            Tab("Audio", systemImage: "speaker.wave.2") {
                audioSettings
            }
            Tab("Performance", systemImage: "waveform.path.ecg") {
                performanceSettings
            }
        }
        .frame(width: 500, height: 460)
    }

    // MARK: - Audio Tab

    private var audioSettings: some View {
        Form {
            Section("Output Device") {
                Picker("Output", selection: Binding(
                    get: { normalizedSelectedOutputUID ?? "default" },
                    set: { newUID in
                        let uid = newUID == "default" ? nil : newUID
                        guard uid != normalizedSelectedOutputUID else { return }
                        appState.settings.selectedOutputDeviceID = uid
                        appState.applyOutputDevice(uid)
                        Task { @MainActor in
                            // Output-device changes may restart the engine; refresh after transition settles.
                            try? await Task.sleep(for: .milliseconds(150))
                            refreshOutputDeviceMetadata()
                        }
                    }
                )) {
                    Text("System Default").tag("default")
                    ForEach(outputPickerDevices) { device in
                        deviceLabel(device).tag(device.uid)
                    }
                }
                .labelsHidden()
            }

            Section("Input Device (Mic & Pitch Tracking)") {
                Picker("Input", selection: Binding(
                    get: { normalizedSelectedInputUID ?? "default" },
                    set: { newUID in
                        let uid = newUID == "default" ? nil : newUID
                        guard uid != normalizedSelectedInputUID else { return }
                        appState.settings.selectedInputDeviceID = uid
                        appState.applyInputDevice(uid)
                    }
                )) {
                    Text("System Default").tag("default")
                    ForEach(inputPickerDevices) { device in
                        deviceLabel(device).tag(device.uid)
                    }
                }
                .labelsHidden()

                Text("Select your headset microphone here to use it for pitch tracking and mic monitoring.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Default Volumes") {
                LabeledContent("Vocal") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { appState.settings.defaultVocalVolume },
                            set: { appState.settings.defaultVocalVolume = $0 }
                        ), in: 0...1)
                        .frame(width: 180)
                        Text("\(Int(appState.settings.defaultVocalVolume * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                LabeledContent("Instrumental") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { appState.settings.defaultInstrumentalVolume },
                            set: { appState.settings.defaultInstrumentalVolume = $0 }
                        ), in: 0...1)
                        .frame(width: 180)
                        Text("\(Int(appState.settings.defaultInstrumentalVolume * 100))%")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section("Audio Buffer Size") {
                Picker("Buffer Size", selection: Binding(
                    get: { appState.settings.bufferFrameSize ?? appState.audioEngine.currentBufferSize },
                    set: { frames in
                        let currentSelection = appState.settings.bufferFrameSize ?? appState.audioEngine.currentBufferSize
                        guard frames != currentSelection else { return }
                        appState.settings.bufferFrameSize = frames
                        appState.audioEngine.setBufferSize(frames)
                    }
                )) {
                    ForEach(bufferSizeOptions, id: \.self) { frames in
                        let ms = String(format: "%.1f ms", Double(frames) / cachedOutputSampleRate * 1000)
                        Text("\(frames) frames (\(ms))").tag(frames)
                    }
                }

                Text("Smaller buffers reduce monitoring latency but may cause audio glitches on slower systems. Use the device's native buffer size (shown in bold) for best compatibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Refresh cached output-device metadata used by the buffer-size section.
    private func refreshOutputDeviceMetadata() {
        if let deviceID = appState.audioEngine.getCurrentOutputDeviceID(),
           let rate = AudioDeviceManager.nominalSampleRate(for: deviceID) {
            cachedOutputSampleRate = rate
            let sizes = AudioDeviceManager.availableBufferSizes(for: deviceID)
            cachedBufferSizeOptions = sizes.isEmpty ? [64, 128, 256, 480, 512, 1024] : sizes
            return
        }
        cachedOutputSampleRate = 48000.0
        cachedBufferSizeOptions = [64, 128, 256, 480, 512, 1024]
    }

    private var outputPickerDevices: [AudioDeviceManager.AudioDevice] {
        var devices = appState.deviceManager.outputDevices
        guard let selectedUID = normalizedSelectedOutputUID,
              !devices.contains(where: { $0.uid == selectedUID }) else {
            return devices
        }
        let fallbackID = appState.deviceManager.deviceID(forUID: selectedUID)
        devices.append(
            AudioDeviceManager.AudioDevice(
                id: fallbackID,
                uid: selectedUID,
                name: "Unavailable Output (Reconnect Device)",
                hasInput: false,
                hasOutput: true,
                isBluetooth: false
            )
        )
        return devices
    }

    private var inputPickerDevices: [AudioDeviceManager.AudioDevice] {
        var devices = appState.deviceManager.inputDevices
        guard let selectedUID = normalizedSelectedInputUID,
              !devices.contains(where: { $0.uid == selectedUID }) else {
            return devices
        }
        let fallbackID = appState.deviceManager.deviceID(forUID: selectedUID)
        devices.append(
            AudioDeviceManager.AudioDevice(
                id: fallbackID,
                uid: selectedUID,
                name: "Unavailable Input (Reconnect Device)",
                hasInput: true,
                hasOutput: false,
                isBluetooth: false
            )
        )
        return devices
    }

    private var bufferSizeOptions: [UInt32] {
        var options = cachedBufferSizeOptions
        let currentSelection = appState.settings.bufferFrameSize ?? appState.audioEngine.currentBufferSize
        if !options.contains(currentSelection) {
            options.append(currentSelection)
            options.sort()
        }
        return options
    }

    private var normalizedSelectedOutputUID: String? {
        guard let uid = appState.settings.selectedOutputDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uid.isEmpty else {
            return nil
        }
        return uid
    }

    private var normalizedSelectedInputUID: String? {
        guard let uid = appState.settings.selectedInputDeviceID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uid.isEmpty else {
            return nil
        }
        return uid
    }

    // MARK: - Performance Tab

    private var performanceSettings: some View {
        Form {
            Section("Pitch Tracking") {
                LabeledContent("Confidence Threshold") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { Double(appState.settings.pitchConfidenceThreshold) },
                            set: { appState.setPitchConfidenceThreshold(Float($0)) }
                        ), in: 0.01...0.2, step: 0.01)
                        .frame(width: 180)
                        Text(String(format: "%.2f", appState.settings.pitchConfidenceThreshold))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Text("Lower values show more pitch data but may include noise. Higher values require stronger signal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Background Visualizer") {
                Toggle("Enable Reactive Visualizer", isOn: Binding(
                    get: { appState.settings.visualizer.isEnabled },
                    set: { appState.setVisualizerEnabled($0) }
                ))

                Picker("Placement", selection: Binding(
                    get: { appState.settings.visualizer.placement },
                    set: { appState.setVisualizerPlacement($0) }
                )) {
                    Text("Lyrics Panel").tag(VisualizerSettings.Placement.lyricsPane)
                    Text("Full Background").tag(VisualizerSettings.Placement.globalBackground)
                }

                LabeledContent("Intensity") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { appState.settings.visualizer.intensity },
                            set: { appState.setVisualizerIntensity($0) }
                        ), in: 0.15...0.8)
                        .frame(width: 180)
                        .disabled(!appState.settings.visualizer.isEnabled)

                        Text(String(format: "%.2f", appState.settings.visualizer.intensity))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                .disabled(!appState.settings.visualizer.isEnabled)

                LabeledContent("Lyrics Scrim") {
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { appState.settings.visualizer.readabilityScrim },
                            set: { appState.setVisualizerReadabilityScrim($0) }
                        ), in: 0.20...0.85)
                        .frame(width: 180)
                        .disabled(
                            !appState.settings.visualizer.isEnabled ||
                                appState.settings.visualizer.placement != .lyricsPane
                        )

                        Text(String(format: "%.2f", appState.settings.visualizer.readabilityScrim))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }

                Text("Renders gradient + reactive waves behind lyrics or across the full performance background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func deviceLabel(_ device: AudioDeviceManager.AudioDevice) -> some View {
        if device.isBluetooth {
            Label(device.name, systemImage: "headphones")
        } else {
            Text(device.name)
        }
    }
}
