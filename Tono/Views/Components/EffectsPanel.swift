import SwiftUI

/// Mic FX chain panel in processing order:
/// Gate -> EQ -> Compressor -> Tuner -> Delay -> Reverb.
struct EffectsPanel: View {
    @Environment(AppState.self) private var appState
    @Bindable var vm: EffectsViewModel
    let micSpectrumAnalyzer: MicSpectrumAnalyzer

    var body: some View {
        VStack(spacing: 20) {
            gateSection
            Divider().background(Color.white.opacity(0.08))
            eqSection
            Divider().background(Color.white.opacity(0.08))
            compressorSection
            Divider().background(Color.white.opacity(0.08))
            tunerSection
            Divider().background(Color.white.opacity(0.08))
            delaySection
            Divider().background(Color.white.opacity(0.08))
            reverbSection
            Divider().background(Color.white.opacity(0.08))
            resetButton
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: TonoRadius.large, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Gate

    private var gateSection: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "1 · GATE",
                icon: "speaker.slash",
                color: TonoColors.red,
                isEnabled: Binding(get: { vm.gateEnabled }, set: { vm.gateEnabled = $0 })
            )
            Group {
                presetPicker(
                    title: "Gate Preset",
                    selection: Binding(get: { vm.gatePreset }, set: { vm.gatePreset = $0 }),
                    values: Array(GatePreset.allCases),
                    label: { $0.title }
                )
                effectRow(
                    label: "Thresh",
                    valueText: dbText(vm.gateThreshold),
                    color: TonoColors.red,
                    value: Binding(get: { vm.gateThreshold }, set: { vm.gateThreshold = $0 }),
                    range: -80...0
                )
                effectRow(
                    label: "Ratio",
                    valueText: ratioText(vm.gateRatio),
                    color: TonoColors.red,
                    value: Binding(get: { vm.gateRatio }, set: { vm.gateRatio = $0 }),
                    range: 1...20
                )
                effectRow(
                    label: "Attack",
                    valueText: timeText(vm.gateAttack),
                    color: TonoColors.red,
                    value: Binding(get: { vm.gateAttack }, set: { vm.gateAttack = $0 }),
                    range: 0.0001...0.2
                )
                effectRow(
                    label: "Release",
                    valueText: timeText(vm.gateRelease),
                    color: TonoColors.red,
                    value: Binding(get: { vm.gateRelease }, set: { vm.gateRelease = $0 }),
                    range: 0.01...3.0
                )
            }
            .opacity(vm.gateEnabled ? 1 : 0.45)
            .disabled(!vm.gateEnabled)
        }
    }

    // MARK: - EQ

    private var eqSection: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "2 · EQ",
                icon: "slider.horizontal.3",
                color: TonoColors.green,
                isEnabled: Binding(get: { vm.eqEnabled }, set: { vm.eqEnabled = $0 })
            )
            EQSpectrumView(analyzer: micSpectrumAnalyzer)
            Group {
                presetPicker(
                    title: "EQ Preset",
                    selection: Binding(get: { vm.eqPreset }, set: { vm.eqPreset = $0 }),
                    values: Array(EQPreset.allCases),
                    label: { $0.title }
                )
                effectRow(
                    label: "Low",
                    valueText: gainText(vm.lowGain),
                    color: gainColor(vm.lowGain),
                    value: Binding(get: { vm.lowGain }, set: { vm.lowGain = $0 }),
                    range: -12...12
                )
                effectRow(
                    label: "Mid",
                    valueText: gainText(vm.midGain),
                    color: gainColor(vm.midGain),
                    value: Binding(get: { vm.midGain }, set: { vm.midGain = $0 }),
                    range: -12...12
                )
                effectRow(
                    label: "High",
                    valueText: gainText(vm.highGain),
                    color: gainColor(vm.highGain),
                    value: Binding(get: { vm.highGain }, set: { vm.highGain = $0 }),
                    range: -12...12
                )
            }
            .opacity(vm.eqEnabled ? 1 : 0.45)
            .disabled(!vm.eqEnabled)
        }
    }

    // MARK: - Compressor

    private var compressorSection: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "3 · COMPRESSOR",
                icon: "waveform.badge.minus",
                color: TonoColors.cyan,
                isEnabled: Binding(get: { vm.compressorEnabled }, set: { vm.compressorEnabled = $0 })
            )
            Group {
                presetPicker(
                    title: "Compressor Preset",
                    selection: Binding(get: { vm.compressorPreset }, set: { vm.compressorPreset = $0 }),
                    values: Array(CompressorPreset.allCases),
                    label: { $0.title }
                )
                effectRow(
                    label: "Thresh",
                    valueText: dbText(vm.compressorThreshold),
                    color: TonoColors.cyan,
                    value: Binding(get: { vm.compressorThreshold }, set: { vm.compressorThreshold = $0 }),
                    range: -40...20
                )
                effectRow(
                    label: "Ratio",
                    valueText: ratioText(vm.compressorRatio),
                    color: TonoColors.cyan,
                    value: Binding(get: { vm.compressorRatio }, set: { vm.compressorRatio = $0 }),
                    range: 1...20
                )
                effectRow(
                    label: "Makeup",
                    valueText: dbText(vm.compressorMakeupGain),
                    color: TonoColors.cyan,
                    value: Binding(get: { vm.compressorMakeupGain }, set: { vm.compressorMakeupGain = $0 }),
                    range: -12...24
                )
            }
            .opacity(vm.compressorEnabled ? 1 : 0.45)
            .disabled(!vm.compressorEnabled)
        }
    }

    // MARK: - Tuner

    private var tunerSection: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "4 · TUNER",
                icon: "tuningfork",
                color: TonoColors.green,
                isEnabled: Binding(get: { vm.tunerEnabled }, set: { vm.tunerEnabled = $0 })
            )
            Text("Corrects monitored mic pitch to your selected key and scale. The pitch display still shows your raw voice.")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(TonoColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                presetPicker(
                    title: "Tuner Key",
                    caption: "Key",
                    helpText: "Pick the song key so correction nudges toward musical target notes.",
                    selection: Binding(get: { vm.tunerKey }, set: { vm.tunerKey = $0 }),
                    values: Array(TunerKey.allCases),
                    label: { $0.title }
                )
                tunerScalePicker
                effectRow(
                    label: "Amount",
                    valueText: percentText(vm.tunerAmount),
                    color: TonoColors.green,
                    value: Binding(get: { vm.tunerAmount }, set: { vm.tunerAmount = $0 }),
                    range: 0...1
                )
                .help("How strongly notes are pulled to the selected scale.")
                effectRow(
                    label: "Speed",
                    valueText: percentText(vm.tunerSpeed),
                    color: TonoColors.green,
                    value: Binding(get: { vm.tunerSpeed }, set: { vm.tunerSpeed = $0 }),
                    range: 0...1
                )
                .help("How quickly pitch snaps to target notes. Higher values sound tighter.")
                tunerResponseSummary
            }
            .opacity(vm.tunerEnabled ? 1 : 0.45)
            .disabled(!vm.tunerEnabled)
        }
        .help("Live mic-only correction. Playback stems are never pitch-corrected.")
    }

    private var tunerScalePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scale")
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(TonoColors.textSecondary)

            Picker("Tuner Scale", selection: Binding(get: { vm.tunerScale }, set: { vm.tunerScale = $0 })) {
                ForEach(TunerScale.allCases, id: \.self) { scale in
                    Text(scale.title).tag(scale)
                }
            }
            .pickerStyle(.segmented)
            .help("Choose note set: Chromatic (all notes), Major, or Minor.")
        }
    }

    private var tunerResponseSummary: some View {
        HStack(spacing: 8) {
            Text("Feel: \(tunerAmountDescriptor)")
            Text("Snap: \(tunerSpeedDescriptor)")
            Spacer()
            Text("Default 75% / 55%")
        }
        .font(.system(.caption2, design: .rounded, weight: .medium))
        .foregroundStyle(TonoColors.textSecondary)
    }

    // MARK: - Delay

    private var delaySection: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "5 · DELAY",
                icon: "repeat",
                color: TonoColors.purple,
                isEnabled: Binding(get: { vm.delayEnabled }, set: { vm.delayEnabled = $0 })
            )
            Group {
                modePicker
                effectRow(
                    label: "Mix",
                    valueText: percentText(vm.delayMix),
                    color: TonoColors.purple,
                    value: Binding(get: { vm.delayMix }, set: { vm.delayMix = $0 }),
                    range: 0...1
                )
                effectRow(
                    label: "Time",
                    valueText: timeText(vm.delayTime),
                    color: TonoColors.purple,
                    value: Binding(get: { vm.delayTime }, set: { vm.delayTime = $0 }),
                    range: 0.01...2.0
                )
                effectRow(
                    label: "Feedback",
                    valueText: percentText(vm.delayFeedback),
                    color: TonoColors.purple,
                    value: Binding(get: { vm.delayFeedback }, set: { vm.delayFeedback = $0 }),
                    range: 0...0.95
                )
            }
            .opacity(vm.delayEnabled ? 1 : 0.45)
            .disabled(!vm.delayEnabled)
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Mode")
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(TonoColors.textSecondary)

            Picker("Delay Mode", selection: Binding(get: { vm.delayMode }, set: { vm.delayMode = $0 })) {
                Text("Standard").tag(DelayMode.standard)
                Text("Slapback Ping-Pong").tag(DelayMode.slapbackPingPong)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - Reverb

    private var reverbSection: some View {
        VStack(spacing: 12) {
            sectionHeader(
                "6 · REVERB",
                icon: "waveform.path.ecg",
                color: TonoColors.cyan,
                isEnabled: Binding(get: { vm.reverbEnabled }, set: { vm.reverbEnabled = $0 })
            )
            Group {
                effectRow(
                    label: "Mix",
                    valueText: percentText(vm.reverbMix),
                    color: TonoColors.cyan,
                    value: Binding(get: { vm.reverbMix }, set: { vm.reverbMix = $0 }),
                    range: 0...1
                )
            }
            .opacity(vm.reverbEnabled ? 1 : 0.45)
            .disabled(!vm.reverbEnabled)
        }
    }

    // MARK: - Reset

    private var resetButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { vm.resetAll() }
        } label: {
            Label("Reset All", systemImage: "arrow.counterclockwise")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(TonoColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: TonoRadius.small, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Reusable Subviews

    private func sectionHeader(
        _ title: String,
        icon: String,
        color: Color,
        isEnabled: Binding<Bool>
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .foregroundStyle(TonoColors.textTertiary)
                .tracking(2)
            Spacer()
            Toggle("", isOn: isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(color)
        }
    }

    private func effectRow(
        label: String,
        valueText: String,
        color: Color,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(TonoColors.textSecondary)
                .frame(width: 58, alignment: .leading)

            Slider(value: value, in: range)
                .tint(color)

            Text(valueText)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func presetPicker<P: Hashable>(
        title: String,
        caption: String = "Preset",
        helpText: String? = nil,
        selection: Binding<P>,
        values: [P],
        label: @escaping (P) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(TonoColors.textSecondary)
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { item in
                    Text(label(item)).tag(item)
                }
            }
            .pickerStyle(.menu)
            if let helpText {
                Text(helpText)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(TonoColors.textSecondary)
            }
        }
    }

    // MARK: - Formatters

    private func percentText(_ v: Double) -> String {
        "\(Int(v * 100))%"
    }

    private func timeText(_ v: Double) -> String {
        v < 1.0 ? "\(Int(v * 1000))ms" : String(format: "%.2fs", v)
    }

    private func dbText(_ v: Double) -> String {
        v == 0 ? "0.0dB" : String(format: "%+.1fdB", v)
    }

    private func ratioText(_ v: Double) -> String {
        String(format: "%.1f:1", v)
    }

    private func gainText(_ v: Double) -> String {
        v == 0 ? "0dB" : String(format: "%+.1fdB", v)
    }

    private func gainColor(_ v: Double) -> Color {
        if abs(v) < 0.5 { return TonoColors.textSecondary }
        return v > 0 ? TonoColors.green : TonoColors.red
    }

    private var tunerAmountDescriptor: String {
        switch vm.tunerAmount {
        case ..<0.35: return "Subtle"
        case ..<0.70: return "Balanced"
        default: return "Strong"
        }
    }

    private var tunerSpeedDescriptor: String {
        switch vm.tunerSpeed {
        case ..<0.35: return "Natural"
        case ..<0.70: return "Tight"
        default: return "Hard Tune"
        }
    }
}
