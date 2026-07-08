import CoreAudio
import Observation

/// An output device the user can pick from the menu.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let uid: String
}

/// Subsystem 1: master volume + mute of the current default output device, plus the
/// list of available output devices and switching between them. All Core Audio reads
/// happen on the main queue (listeners are registered with `.main`), so the
/// `@Observable` state is safe to touch directly.
@Observable
final class MasterVolumeController {
    private(set) var devices: [AudioDevice] = []
    private(set) var defaultDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    /// 0.0 … 1.0. Setting drives the hardware; hardware/media-key changes drive it back.
    private(set) var volume: Double = 0
    private(set) var muted: Bool = false
    private(set) var volumeControllable: Bool = false

    /// Called on the main queue after the default output device changes (used to
    /// rebuild per-app taps, whose aggregates embed the old device).
    var onDefaultDeviceChanged: (() -> Void)?

    // Suppress the feedback loop: our own writes trigger the listener, which would
    // otherwise re-read and stomp the value mid-drag.
    private var applyingLocally = false

    private var systemListeners: [CA.ListenerToken] = []
    private var deviceListeners: [CA.ListenerToken] = []

    init() {
        refreshDevices()
        rebindToDefaultDevice()

        // React to device hot-plug and default-device changes.
        systemListeners.append(
            CA.listen(CA.system, CA.address(kAudioHardwarePropertyDevices)) { [weak self] in
                self?.refreshDevices()
            }
        )
        systemListeners.append(
            CA.listen(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
                self?.rebindToDefaultDevice()
            }
        )
    }

    // MARK: - Device enumeration

    func refreshDevices() {
        let ids = CA.array(CA.system, CA.address(kAudioHardwarePropertyDevices), of: AudioObjectID.self)
        devices = ids.compactMap { id in
            guard Self.hasOutputStreams(id) else { return nil }
            let uid = CA.string(id, CA.address(kAudioDevicePropertyDeviceUID)) ?? ""
            // Hide our own per-app tap aggregate devices from the picker.
            guard !uid.hasPrefix(ProcessTap.aggregateUIDPrefix) else { return nil }
            let name = CA.string(id, CA.address(kAudioObjectPropertyName)) ?? "Device \(id)"
            return AudioDevice(id: id, name: name, uid: uid)
        }
    }

    static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        var addr = CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    func selectDevice(_ device: AudioDevice) {
        CA.setValue(CA.system, CA.address(kAudioHardwarePropertyDefaultOutputDevice), device.id)
        // The default-device listener will fire and call rebindToDefaultDevice().
    }

    // MARK: - Bind volume/mute to the current default device

    private func rebindToDefaultDevice() {
        deviceListeners.removeAll()
        defaultDeviceID = CA.value(
            CA.system,
            CA.address(kAudioHardwarePropertyDefaultOutputDevice),
            fallback: AudioObjectID(kAudioObjectUnknown)
        )

        guard defaultDeviceID != AudioObjectID(kAudioObjectUnknown) else {
            volumeControllable = false
            return
        }

        volumeControllable = volumeAddress() != nil
        readVolume()
        readMute()

        // Track hardware/media-key volume + mute changes on this device.
        if let addr = volumeAddress() {
            deviceListeners.append(CA.listen(defaultDeviceID, addr) { [weak self] in
                guard let self, !self.applyingLocally else { return }
                self.readVolume()
            })
        }
        let muteAddr = CA.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        if CA.hasProperty(defaultDeviceID, muteAddr) {
            deviceListeners.append(CA.listen(defaultDeviceID, muteAddr) { [weak self] in
                guard let self, !self.applyingLocally else { return }
                self.readMute()
            })
        }

        onDefaultDeviceChanged?()
    }

    /// Preferred volume property: the device "main element" scalar. Falls back to
    /// per-channel (element 1) if the device exposes no main volume control.
    private func volumeAddress() -> AudioObjectPropertyAddress? {
        let main = CA.address(kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeOutput)
        if CA.hasProperty(defaultDeviceID, main) { return main }
        let ch1 = CA.address(kAudioDevicePropertyVolumeScalar,
                             scope: kAudioObjectPropertyScopeOutput, element: 1)
        if CA.hasProperty(defaultDeviceID, ch1) { return ch1 }
        return nil
    }

    private func readVolume() {
        guard let addr = volumeAddress() else { volumeControllable = false; return }
        let v = CA.value(defaultDeviceID, addr, fallback: Float32(0))
        volume = Double(max(0, min(1, v)))
    }

    private func readMute() {
        let addr = CA.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        guard CA.hasProperty(defaultDeviceID, addr) else { muted = false; return }
        muted = CA.value(defaultDeviceID, addr, fallback: UInt32(0)) != 0
    }

    // MARK: - Setters (called from the UI)

    func setVolume(_ newValue: Double) {
        let clamped = max(0, min(1, newValue))
        volume = clamped
        guard let addr = volumeAddress() else { return }
        applyingLocally = true
        defer { applyingLocally = false }

        // Some devices only accept per-channel writes; set both if main isn't settable.
        if addr.mElement == kAudioObjectPropertyElementMain, CA.isSettable(defaultDeviceID, addr) {
            CA.setValue(defaultDeviceID, addr, Float32(clamped))
        } else {
            for channel: AudioObjectPropertyElement in [1, 2] {
                let chAddr = CA.address(kAudioDevicePropertyVolumeScalar,
                                        scope: kAudioObjectPropertyScopeOutput, element: channel)
                if CA.hasProperty(defaultDeviceID, chAddr) {
                    CA.setValue(defaultDeviceID, chAddr, Float32(clamped))
                }
            }
        }
    }

    func setMuted(_ newValue: Bool) {
        muted = newValue
        let addr = CA.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)
        guard CA.hasProperty(defaultDeviceID, addr), CA.isSettable(defaultDeviceID, addr) else { return }
        applyingLocally = true
        defer { applyingLocally = false }
        CA.setValue(defaultDeviceID, addr, UInt32(newValue ? 1 : 0))
    }

    func toggleMute() { setMuted(!muted) }
}
