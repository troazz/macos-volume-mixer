import AppKit
import CoreAudio
import Darwin
import Observation

/// One application currently producing audio output.
struct AudioApp: Identifiable, Hashable {
    let id: AudioObjectID          // Core Audio process-object ID
    let pid: pid_t
    let bundleID: String?          // the audio process's bundle id (a helper, for browsers)
    let ownerBundleID: String?     // the owning app's bundle id (e.g. Arc's main app)
    let name: String
    let icon: NSImage?             // resolved at build time (incl. helper→parent)
    let isRunningOutput: Bool

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.isRunningOutput == rhs.isRunningOutput
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Surfaces the apps producing audio output as `AudioApp`s.
///
/// Core Audio's change notifications for `isRunningOutput` proved unreliable (a
/// browser's audio helper process only appears once playback starts), so we poll the
/// process list on a short timer in addition to listening for process add/remove.
/// Browsers and Electron apps play through helper processes that `NSRunningApplication`
/// can't resolve, so we walk up the parent-PID chain to find the real owning app for
/// the name and icon.
@Observable
final class AudioProcessMonitor {
    /// Apps currently producing output, sorted by name.
    private(set) var apps: [AudioApp] = []

    /// Called on the main queue after `apps` changes (used to reconcile taps).
    var onAppsChanged: (() -> Void)?

    private var listListener: CA.ListenerToken?
    private var pollTimer: Timer?

    private static let ownPID = getpid()

    init() {
        refresh()
        listListener = CA.listen(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            self?.refresh()
        }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// Re-read the process list and rebuild the app list (idempotent; only publishes
    /// when the result actually changes).
    func refresh() {
        let ids = CA.array(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList), of: AudioObjectID.self)

        let built: [AudioApp] = ids.compactMap { id in
            let running = CA.value(id, CA.address(kAudioProcessPropertyIsRunningOutput),
                                   fallback: UInt32(0)) != 0
            guard running else { return nil }

            let pid = CA.value(id, CA.address(kAudioProcessPropertyPID), fallback: pid_t(-1))
            guard pid != Self.ownPID else { return nil }   // don't list ourselves

            let bundleID = CA.string(id, CA.address(kAudioProcessPropertyBundleID))
            let owner = Self.owningApp(pid: pid)

            // Drop nameless system-audio processes (no owning app and no bundle ID).
            guard owner != nil || !(bundleID?.isEmpty ?? true) else { return nil }

            return AudioApp(
                id: id,
                pid: pid,
                bundleID: bundleID,
                ownerBundleID: owner?.bundleIdentifier,
                name: owner?.localizedName ?? Self.fallbackName(bundleID: bundleID, pid: pid),
                icon: owner?.icon,
                isRunningOutput: running
            )
        }

        let sorted = built.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard sorted != apps else { return }
        apps = sorted
        onAppsChanged?()
    }

    // MARK: - Owning-app resolution

    /// The regular/accessory app that owns `pid`, walking up the parent chain so a
    /// browser/Electron audio helper resolves to the real app (e.g. Arc, Chrome).
    private static func owningApp(pid: pid_t) -> NSRunningApplication? {
        var current = pid
        var depth = 0
        while current > 1, depth < 8 {
            if let app = NSRunningApplication(processIdentifier: current) { return app }
            guard let parent = parentPID(of: current), parent != current else { break }
            current = parent
            depth += 1
        }
        return nil
    }

    /// Parent PID via `sysctl(KERN_PROC_PID)` — no private API.
    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { mibPtr in
            sysctl(mibPtr.baseAddress, UInt32(mibPtr.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    private static func fallbackName(bundleID: String?, pid: pid_t) -> String {
        if let bundleID, !bundleID.isEmpty {
            return bundleID.components(separatedBy: ".").last ?? bundleID
        }
        return "PID \(pid)"
    }
}
