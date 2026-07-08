import CoreAudio
import Foundation

/// Thin, Swift-friendly wrappers around the `AudioObjectGet/SetPropertyData` C API,
/// plus block-based property-listener registration. Everything routes through here
/// so the higher-level controllers stay readable.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Build a property address with sensible defaults (global scope, main element).
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func hasProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(object, &addr)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(object, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    /// Read a single fixed-layout value (Int32, UInt32, Float32, AudioObjectID, …).
    /// Returns `fallback` on any error so callers don't have to unwrap everywhere.
    static func value<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        fallback: T
    ) -> T {
        var addr = address
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value : fallback
    }

    /// Write a single fixed-layout value. Returns the OSStatus (noErr on success).
    @discardableResult
    static func setValue<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        _ value: T
    ) -> OSStatus {
        var addr = address
        var v = value
        let size = UInt32(MemoryLayout<T>.size)
        return AudioObjectSetPropertyData(object, &addr, 0, nil, size, &v)
    }

    /// Read a variable-length array property (e.g. device or process object lists).
    static func array<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        of type: T.Type = T.self
    ) -> [T] {
        var addr = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            var dataSize = size
            let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &dataSize, buffer.baseAddress!)
            initialized = (status == noErr) ? Int(dataSize) / MemoryLayout<T>.stride : 0
        }
    }

    /// Read a CFString property (device names, bundle IDs). Takes ownership of the
    /// +1 reference Core Audio returns, so there is no leak.
    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var addr = address
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    // MARK: - Listeners

    /// Opaque token that removes its listener when you call `cancel()` (or deinit).
    final class ListenerToken {
        private let object: AudioObjectID
        private var address: AudioObjectPropertyAddress
        private let block: AudioObjectPropertyListenerBlock
        private let queue: DispatchQueue
        private var active = true

        init(object: AudioObjectID,
             address: AudioObjectPropertyAddress,
             queue: DispatchQueue,
             block: @escaping AudioObjectPropertyListenerBlock) {
            self.object = object
            self.address = address
            self.queue = queue
            self.block = block
            AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block)
        }

        func cancel() {
            guard active else { return }
            active = false
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }

        deinit { cancel() }
    }

    /// Register a listener; `handler` is called (on `queue`) whenever the property changes.
    static func listen(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) -> ListenerToken {
        ListenerToken(object: object, address: address, queue: queue) { _, _ in handler() }
    }
}
