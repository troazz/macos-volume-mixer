import AudioToolbox
import CoreAudio
import Foundation

/// Intercepts one process's audio and re-renders it at an adjustable gain.
///
/// Mechanism (macOS 14.4+): a Core Audio process tap with `.mutedWhenTapped` removes
/// the app's audio from its normal output path and hands us a copy. We wrap that tap
/// in a *private* aggregate device whose main sub-device is the real output device,
/// then run an IOProc that multiplies the tapped samples by `gain` and writes them to
/// the output — so the user hears the app at the volume we choose (0 … boost).
final class ProcessTap {
    let processObjectID: AudioObjectID

    private let outputDeviceUID: String
    private let queue: DispatchQueue

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// Read on the real-time audio thread. A naturally-aligned 32-bit load/store is
    /// atomic on the platforms we target, so no lock is needed on the hot path.
    private let gainPtr: UnsafeMutablePointer<Float32>

    private(set) var isRunning = false
    private(set) var lastError: String?

    init(processObjectID: AudioObjectID, outputDeviceUID: String, initialGain: Float32, queue: DispatchQueue) {
        self.processObjectID = processObjectID
        self.outputDeviceUID = outputDeviceUID
        self.queue = queue
        self.gainPtr = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
        self.gainPtr.initialize(to: initialGain)
    }

    /// Update the applied gain (0 = silent, 1 = unchanged, >1 = boost). Cheap; safe to call often.
    func setGain(_ gain: Float32) { gainPtr.pointee = gain }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        // 1. Create the tap, muted from its normal output while we have it.
        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.uuid = UUID()
        description.muteBehavior = .mutedWhenTapped
        description.name = "VolumeMixerTap-\(processObjectID)"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr, newTapID != kAudioObjectUnknown else {
            lastError = "AudioHardwareCreateProcessTap failed: \(err)"
            return false
        }
        tapID = newTapID

        // 2. Wrap it in a private aggregate device fronting the real output device.
        let aggregateUID = UUID().uuidString
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer-\(processObjectID)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        var newAggregate = AudioObjectID(kAudioObjectUnknown)
        err = AudioHardwareCreateAggregateDevice(config as CFDictionary, &newAggregate)
        guard err == noErr, newAggregate != kAudioObjectUnknown else {
            lastError = "AudioHardwareCreateAggregateDevice failed: \(err)"
            cleanup()
            return false
        }
        aggregateID = newAggregate

        // 3. IOProc: scaled copy of tap input → device output.
        let gainPtr = self.gainPtr
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            let gain = gainPtr.pointee
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)
            let paired = min(input.count, output.count)

            var i = 0
            while i < paired {
                let inBuffer = input[i]
                let outBuffer = output[i]
                if let src = inBuffer.mData, let dst = outBuffer.mData {
                    let copyBytes = min(inBuffer.mDataByteSize, outBuffer.mDataByteSize)
                    if gain == 1.0 {
                        memcpy(dst, src, Int(copyBytes))
                    } else {
                        let count = Int(copyBytes) / MemoryLayout<Float32>.size
                        let s = src.assumingMemoryBound(to: Float32.self)
                        let d = dst.assumingMemoryBound(to: Float32.self)
                        var f = 0
                        while f < count { d[f] = s[f] * gain; f += 1 }
                    }
                    // Silence any trailing bytes the input didn't fill.
                    if outBuffer.mDataByteSize > copyBytes {
                        memset(dst.advanced(by: Int(copyBytes)), 0, Int(outBuffer.mDataByteSize - copyBytes))
                    }
                }
                i += 1
            }
            // Silence output buffers with no matching input stream.
            var j = paired
            while j < output.count {
                if let dst = output[j].mData { memset(dst, 0, Int(output[j].mDataByteSize)) }
                j += 1
            }
        }

        var newProcID: AudioDeviceIOProcID?
        err = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, queue, ioBlock)
        guard err == noErr, let newProcID else {
            lastError = "AudioDeviceCreateIOProcIDWithBlock failed: \(err)"
            cleanup()
            return false
        }
        ioProcID = newProcID

        err = AudioDeviceStart(aggregateID, newProcID)
        guard err == noErr else {
            lastError = "AudioDeviceStart failed: \(err)"
            cleanup()
            return false
        }

        isRunning = true
        return true
    }

    func stop() { cleanup() }

    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        isRunning = false
    }

    deinit {
        cleanup()
        gainPtr.deinitialize(count: 1)
        gainPtr.deallocate()
    }
}
