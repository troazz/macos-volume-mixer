import CoreAudio
import Foundation

/// Owns one `ProcessTap` per controlled app and reconciles them against the desired
/// per-app gains. A tap is created lazily the first time an app leaves unity gain (or
/// is muted); once created it is kept alive while the app exists — subsequent volume
/// changes are cheap atomic gain writes, avoiding audible create/destroy churn. Taps
/// are torn down when the app disappears, the output device changes, or the user
/// resets the app.
///
/// **Loudness normalization:** re-rendering through a tap/aggregate has been reported
/// to attenuate the signal by a factor that scales with the output device's number of
/// stereo pairs. We counteract that with a compensation multiplier derived from the
/// device's channel count — a no-op for ordinary 2-channel devices, a boost only on
/// multichannel hardware where the attenuation actually appears.
final class TapMixerEngine {
    private let ioQueue = DispatchQueue(label: "com.volumemixer.tap-io", qos: .userInitiated)
    private var taps: [AudioObjectID: ProcessTap] = [:]   // keyed by process object ID

    func hasTap(for processObjectID: AudioObjectID) -> Bool { taps[processObjectID] != nil }

    /// Reconcile taps against `apps`. `effectiveGain(app)` returns the desired linear
    /// gain (0 = muted), or `nil` when the app needs no interception (unity + unmuted
    /// and no existing tap).
    func reconcile(apps: [AudioApp], effectiveGain: (AudioApp) -> Float32?) {
        // Remove taps whose app is gone.
        let live = Set(apps.map(\.id))
        for id in taps.keys where !live.contains(id) {
            taps[id]?.stop()
            taps.removeValue(forKey: id)
        }

        guard let output = Self.currentOutput() else { return }
        let compensation = Self.loudnessCompensation(for: output.id)

        for app in apps {
            guard let gain = effectiveGain(app) else { continue }
            let finalGain = gain * compensation
            if let existing = taps[app.id] {
                existing.setGain(finalGain)
            } else {
                let tap = ProcessTap(processObjectID: app.id,
                                     outputDeviceUID: output.uid,
                                     initialGain: finalGain,
                                     queue: ioQueue)
                if tap.start() {
                    taps[app.id] = tap
                }
                // If start() failed, we simply don't track it; the app keeps playing
                // at full volume and the next reconcile can retry.
            }
        }
    }

    /// Output device changed: aggregates embed the old device UID, so rebuild all.
    func rebuildAll(apps: [AudioApp], effectiveGain: (AudioApp) -> Float32?) {
        teardownAll()
        reconcile(apps: apps, effectiveGain: effectiveGain)
    }

    /// Release the tap for one app (used by "Reset"), returning it to the direct path.
    func dropTap(for processObjectID: AudioObjectID) {
        taps[processObjectID]?.stop()
        taps.removeValue(forKey: processObjectID)
    }

    func teardownAll() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
    }

    // MARK: - Output device helpers

    private static func currentOutput() -> (id: AudioObjectID, uid: String)? {
        let device = CA.value(CA.system,
                              CA.address(kAudioHardwarePropertyDefaultOutputDevice),
                              fallback: AudioObjectID(kAudioObjectUnknown))
        guard device != kAudioObjectUnknown,
              let uid = CA.string(device, CA.address(kAudioDevicePropertyDeviceUID))
        else { return nil }
        return (device, uid)
    }

    /// Compensation multiplier = max(1, channels / 2). Stereo → 1.0 (no change).
    static func loudnessCompensation(for device: AudioObjectID) -> Float32 {
        let channels = outputChannelCount(device)
        return max(1.0, Float32(channels) / 2.0)
    }

    /// Total output channels from the device's stream configuration.
    static func outputChannelCount(_ device: AudioObjectID) -> Int {
        var addr = CA.address(kAudioDevicePropertyStreamConfiguration,
                              scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else {
            return 2
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 2 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        let channels = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels > 0 ? channels : 2
    }

    deinit { teardownAll() }
}
