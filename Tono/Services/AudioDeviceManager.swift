import CoreAudio
import AudioToolbox

/// Enumerates and identifies system audio devices for input/output selection.
/// Automatically refreshes when devices are added, removed, or change (e.g. Bluetooth connect/disconnect).
@MainActor
@Observable
final class AudioDeviceManager {

    struct AudioDevice: Identifiable, Hashable, Sendable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let hasInput: Bool
        let hasOutput: Bool
        /// True when the CoreAudio transport type is Bluetooth or Bluetooth LE.
        let isBluetooth: Bool
    }

    private(set) var inputDevices:  [AudioDevice] = []
    private(set) var outputDevices: [AudioDevice] = []

    // Holds the CoreAudio listener block and registration flag.
    // Wrapped in a class so the reference survives deinit (which is nonisolated)
    // without needing nonisolated(unsafe) on a value-type stored property.
    private let listenerState = ListenerState()

    init() {
        refresh()
        installDeviceListChangedListener()
    }

    deinit {
        listenerState.removeIfInstalled()
    }

    func refresh() {
        let allDevices = Self.getAllDevices()
        inputDevices  = allDevices.filter(\.hasInput)
        outputDevices = allDevices.filter(\.hasOutput)
    }

    /// Look up the CoreAudio `AudioDeviceID` for a stored UID string.
    /// Returns `kAudioObjectUnknown` if not found.
    func deviceID(forUID uid: String) -> AudioDeviceID {
        (inputDevices + outputDevices).first(where: { $0.uid == uid })?.id
            ?? AudioDeviceID(kAudioObjectUnknown)
    }

    // MARK: - Buffer Size Control

    /// Query the supported buffer frame size range for a device.
    static func bufferSizeRange(for deviceID: AudioDeviceID) -> ClosedRange<UInt32>? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var range = AudioValueRange(mMinimum: 0, mMaximum: 0)
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &range) == noErr else {
            return nil
        }
        return UInt32(range.mMinimum)...UInt32(range.mMaximum)
    }

    /// Query the current hardware buffer frame size for a device.
    static func currentBufferFrameSize(for deviceID: AudioDeviceID) -> UInt32? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &frames) == noErr else {
            return nil
        }
        return frames
    }

    /// Query the device nominal sample rate.
    static func nominalSampleRate(for deviceID: AudioDeviceID) -> Double? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &sampleRate) == noErr,
              sampleRate > 0 else {
            return nil
        }
        return sampleRate
    }

    /// Set the hardware buffer frame size for a device.
    /// Returns `true` on success.
    @discardableResult
    static func setBufferFrameSize(_ frames: UInt32, for deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = frames
        let err = AudioObjectSetPropertyData(
            deviceID, &addr, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        )
        if err != noErr {
            print("[AudioDeviceManager] setBufferFrameSize(\(frames)) error: \(err)")
        }
        return err == noErr
    }

    /// Return the subset of common buffer size presets supported by the given device.
    /// Includes the device's current hardware buffer size even if it is not a
    /// power-of-2 (e.g. MOTU M2 uses 480 frames at 48 kHz). This ensures the
    /// user can see and select the device's native buffer size.
    static func availableBufferSizes(for deviceID: AudioDeviceID) -> [UInt32] {
        let presets: [UInt32] = [32, 64, 128, 256, 480, 512, 1024, 2048]
        guard let range = bufferSizeRange(for: deviceID) else { return presets }
        var sizes = presets.filter { range.contains($0) }

        // If the device is currently using a non-standard buffer size (e.g. 480),
        // include it so the user can see and re-select the native size.
        if let current = currentBufferFrameSize(for: deviceID),
           !sizes.contains(current), range.contains(current) {
            sizes.append(current)
            sizes.sort()
        }

        return sizes
    }

    // MARK: - Automatic Refresh via CoreAudio Property Listener

    private func installDeviceListChangedListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        listenerState.block = block

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let err = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        if err == noErr { listenerState.installed = true }
    }

    // MARK: - CoreAudio Queries

    private static func getAllDevices() -> [AudioDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize
        ) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard let name = getDeviceName(deviceID),
                  let uid  = getDeviceUID(deviceID) else { return nil }

            let hasInput  = channelCount(for: deviceID, scope: kAudioDevicePropertyScopeInput)  > 0
            let hasOutput = channelCount(for: deviceID, scope: kAudioDevicePropertyScopeOutput) > 0

            guard hasInput || hasOutput else { return nil }

            return AudioDevice(id: deviceID, uid: uid, name: name,
                               hasInput: hasInput, hasOutput: hasOutput,
                               isBluetooth: transportIsBluetooth(deviceID))
        }
    }

    // MARK: - Transport Type

    private static func transportIsBluetooth(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &transport) == noErr else {
            return false
        }
        return transport == kAudioDeviceTransportTypeBluetooth ||
               transport == kAudioDeviceTransportTypeBluetoothLE
    }

    // MARK: - Property Helpers

    private static func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        getCFStringProperty(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }

    private static func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        getCFStringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    private static func getCFStringProperty(_ deviceID: AudioDeviceID,
                                             selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        var unmanagedValue: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &unmanagedValue) == noErr,
              let cfString = unmanagedValue?.takeUnretainedValue() else { return nil }
        return cfString as String
    }

    private static func channelCount(for deviceID: AudioDeviceID,
                                      scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPointer) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(bufferListPointer).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}

// MARK: - ListenerState

/// Plain reference type that holds the CoreAudio property listener block and its
/// registration flag.  Being a class means it is accessible from a nonisolated
/// deinit without requiring nonisolated(unsafe) on a value-type stored property.
private final class ListenerState: @unchecked Sendable {
    var block: AudioObjectPropertyListenerBlock?
    var installed = false

    func removeIfInstalled() {
        guard installed, let block else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
        installed = false
    }
}
