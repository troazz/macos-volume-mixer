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
    /// Prefix on our private aggregate devices' UIDs so the output-device picker can
    /// recognize and hide them (they must never be user-selectable outputs).
    static let aggregateUIDPrefix = "SwaraAgg-"

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
        description.name = "SwaraTap-\(processObjectID)"

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var err = AudioHardwareCreateProcessTap(description, &newTapID)
        guard err == noErr, newTapID != kAudioObjectUnknown else {
            lastError = "AudioHardwareCreateProcessTap failed: \(err)"
            return false
        }
        tapID = newTapID

        // 2. Wrap it in a private aggregate device fronting the real output device.
        let aggregateUID = Self.aggregateUIDPrefix + UUID().uuidString
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Swara-\(processObjectID)",
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

        // 3. IOProc: channel/interleave-aware scaled copy of tap input → device output.
        let gainPtr = self.gainPtr
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            let gain = gainPtr.pointee
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let output = UnsafeMutableAudioBufferListPointer(outOutputData)
            ProcessTap.mix(from: input, to: output, gain: gain)
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

    // MARK: - Real-time mixing

    /// Copy `input` → `output` per channel, applying `gain`, correctly handling
    /// interleaved vs. non-interleaved layouts and differing channel counts (the tap
    /// mixdown is interleaved stereo; most output devices are non-interleaved — a
    /// naive byte copy between them is what produced the "robot" garble). Assumes
    /// Float32 samples at a matching sample rate (the aggregate resamples sub-devices
    /// to its nominal rate, so frame counts line up).
    static func mix(from input: UnsafeMutableAudioBufferListPointer,
                    to output: UnsafeMutableAudioBufferListPointer,
                    gain: Float32) {
        guard output.count > 0 else { return }

        let outInterleaved = output.count == 1 && output[0].mNumberChannels > 1
        let outChannels = outInterleaved ? Int(output[0].mNumberChannels) : output.count
        let outFrames = outInterleaved
            ? Int(output[0].mDataByteSize) / (Int(output[0].mNumberChannels) * MemoryLayout<Float32>.size)
            : Int(output[0].mDataByteSize) / MemoryLayout<Float32>.size

        // No usable input → output silence.
        guard input.count > 0, input[0].mData != nil else {
            for buffer in output {
                if let dst = buffer.mData { memset(dst, 0, Int(buffer.mDataByteSize)) }
            }
            return
        }

        let inInterleaved = input.count == 1 && input[0].mNumberChannels > 1
        let inChannels = inInterleaved ? Int(input[0].mNumberChannels) : input.count
        let inFrames = inInterleaved
            ? Int(input[0].mDataByteSize) / (Int(input[0].mNumberChannels) * MemoryLayout<Float32>.size)
            : Int(input[0].mDataByteSize) / MemoryLayout<Float32>.size

        let frames = min(inFrames, outFrames)

        // (base pointer, stride between successive frames of a channel).
        func inChannel(_ ch: Int) -> (UnsafeMutablePointer<Float32>, Int)? {
            if inInterleaved {
                guard let base = input[0].mData?.assumingMemoryBound(to: Float32.self) else { return nil }
                return (base + ch, inChannels)
            } else {
                guard ch < input.count, let base = input[ch].mData?.assumingMemoryBound(to: Float32.self) else { return nil }
                return (base, 1)
            }
        }
        func outChannel(_ ch: Int) -> (UnsafeMutablePointer<Float32>, Int)? {
            if outInterleaved {
                guard let base = output[0].mData?.assumingMemoryBound(to: Float32.self) else { return nil }
                return (base + ch, outChannels)
            } else {
                guard ch < output.count, let base = output[ch].mData?.assumingMemoryBound(to: Float32.self) else { return nil }
                return (base, 1)
            }
        }

        for co in 0..<outChannels {
            guard let (dst, dStride) = outChannel(co) else { continue }
            // Map output channel to an input channel (duplicate last if fewer inputs).
            let ci = co < inChannels ? co : inChannels - 1
            if let (src, sStride) = inChannel(ci) {
                var f = 0
                while f < frames {
                    dst[f * dStride] = src[f * sStride] * gain
                    f += 1
                }
                var t = frames
                while t < outFrames { dst[t * dStride] = 0; t += 1 }  // pad if short
            } else {
                var t = 0
                while t < outFrames { dst[t * dStride] = 0; t += 1 }
            }
        }
    }

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
