import AppKit
import CoreAudio
import Observation

/// One application currently (or recently) producing audio output.
struct AudioApp: Identifiable, Hashable {
    let id: AudioObjectID          // Core Audio process-object ID
    let pid: pid_t
    let bundleID: String?
    let name: String
    let isRunningOutput: Bool

    var icon: NSImage? {
        if let app = NSRunningApplication(processIdentifier: pid) { return app.icon }
        return nil
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.isRunningOutput == rhs.isRunningOutput
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Subsystem 2 (discovery half): enumerates Core Audio process objects and surfaces
/// the ones producing output as `AudioApp`s, kept live via property listeners.
@Observable
final class AudioProcessMonitor {
    /// Apps currently producing output, sorted by name.
    private(set) var apps: [AudioApp] = []

    /// Called on the main queue after `apps` changes (used to reconcile taps).
    var onAppsChanged: (() -> Void)?

    private var listListener: CA.ListenerToken?
    private var perProcessListeners: [AudioObjectID: CA.ListenerToken] = [:]

    init() {
        refresh()
        listListener = CA.listen(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            self?.refresh()
        }
    }

    /// All process objects known to Core Audio (running or not).
    private func processObjectIDs() -> [AudioObjectID] {
        CA.array(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)
    }

    private func refresh() {
        let ids = processObjectIDs()

        // Keep per-process `isRunningOutput` listeners in sync with the live set.
        let idSet = Set(ids)
        for gone in perProcessListeners.keys where !idSet.contains(gone) {
            perProcessListeners.removeValue(forKey: gone)
        }
        for id in ids where perProcessListeners[id] == nil {
            let addr = CA.address(kAudioProcessPropertyIsRunningOutput)
            perProcessListeners[id] = CA.listen(id, addr) { [weak self] in self?.rebuildAppList() }
        }

        rebuildAppList(using: ids)
    }

    private func rebuildAppList(using ids: [AudioObjectID]? = nil) {
        let ids = ids ?? processObjectIDs()
        let built: [AudioApp] = ids.compactMap { id in
            let running = CA.value(id, CA.address(kAudioProcessPropertyIsRunningOutput),
                                   fallback: UInt32(0)) != 0
            guard running else { return nil }

            let pid = CA.value(id, CA.address(kAudioProcessPropertyPID), fallback: pid_t(-1))
            let bundleID = CA.string(id, CA.address(kAudioProcessPropertyBundleID))
            return AudioApp(id: id, pid: pid, bundleID: bundleID,
                            name: Self.displayName(pid: pid, bundleID: bundleID),
                            isRunningOutput: running)
        }
        let sorted = built.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard sorted != apps else { return }
        apps = sorted
        onAppsChanged?()
    }

    private static func displayName(pid: pid_t, bundleID: String?) -> String {
        if pid >= 0, let running = NSRunningApplication(processIdentifier: pid),
           let name = running.localizedName, !name.isEmpty {
            return name
        }
        if let bundleID, !bundleID.isEmpty {
            return bundleID.components(separatedBy: ".").last ?? bundleID
        }
        return "PID \(pid)"
    }
}
