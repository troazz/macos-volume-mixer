import CoreAudio
import Observation

/// Top-level UI state: owns the audio controllers, the per-app tap engine, and the
/// capture-permission object. Holds per-app volume/mute keyed by a stable identity
/// (bundle ID when available, else PID) and drives the engine to reconcile taps
/// whenever those values, the app list, the output device, or permission change.
@Observable
final class AppMixerStore {
    let master = MasterVolumeController()
    let processes = AudioProcessMonitor()
    let permission = AudioCapturePermission()
    let nowPlaying = NowPlayingController()

    @ObservationIgnored private let engine = TapMixerEngine()

    /// Per-app linear gain. 1.0 == unchanged; up to 2.0 == +6 dB boost in the UI.
    static let maxGain: Double = 2.0

    private var gains: [String: Double] = [:]
    private var mutes: Set<String> = []

    init() {
        // Reapply persisted per-app settings.
        gains = VolumeSettings.loadGains()
        mutes = VolumeSettings.loadMutes()

        processes.onAppsChanged = { [weak self] in self?.reconcile() }
        master.onDefaultDeviceChanged = { [weak self] in self?.rebuildAll() }

        reconcile()
        nowPlaying.start()
    }

    // MARK: - Now Playing / transport

    /// The current Now Playing media if it belongs to this app's row — i.e. this row is
    /// the active music/video source. Returns nil for meeting apps (no Now Playing
    /// session) and for media apps that aren't the current session.
    func transport(for app: AudioApp) -> NowPlaying? {
        guard let np = nowPlaying.current else { return nil }
        let ids = [app.bundleID, app.ownerBundleID].compactMap { $0 }
        let matches = ids.contains(np.bundleID)
            || (np.parentBundleID.map { ids.contains($0) } ?? false)
        return matches ? np : nil
    }

    func playPause(for app: AudioApp) { if transport(for: app) != nil { nowPlaying.send(.togglePlayPause) } }
    func nextTrack(for app: AudioApp) { if transport(for: app) != nil { nowPlaying.send(.nextTrack) } }
    func previousTrack(for app: AudioApp) { if transport(for: app) != nil { nowPlaying.send(.previousTrack) } }

    // MARK: - Per-app state

    func key(for app: AudioApp) -> String { app.bundleID ?? "pid:\(app.pid)" }

    func volume(for app: AudioApp) -> Double { gains[key(for: app)] ?? 1.0 }

    func setVolume(_ value: Double, for app: AudioApp) {
        let clamped = max(0, min(Self.maxGain, value))
        gains[key(for: app)] = clamped
        VolumeSettings.saveGains(gains)
        ensurePermissionThenReconcile()
    }

    func isMuted(for app: AudioApp) -> Bool { mutes.contains(key(for: app)) }

    func setMuted(_ muted: Bool, for app: AudioApp) {
        let key = key(for: app)
        if muted { mutes.insert(key) } else { mutes.remove(key) }
        VolumeSettings.saveMutes(mutes)
        ensurePermissionThenReconcile()
    }

    func toggleMute(for app: AudioApp) { setMuted(!isMuted(for: app), for: app) }

    /// True when the app is at its untouched default (unity gain, unmuted).
    func isDefault(for app: AudioApp) -> Bool {
        let key = key(for: app)
        return !mutes.contains(key) && (gains[key] ?? 1.0) == 1.0
    }

    /// Return an app to the direct path: clear its gain/mute, release its tap.
    func reset(for app: AudioApp) {
        let key = key(for: app)
        gains.removeValue(forKey: key)
        mutes.remove(key)
        VolumeSettings.saveGains(gains)
        VolumeSettings.saveMutes(mutes)
        engine.dropTap(for: app.id)
        reconcile()
    }

    // MARK: - Engine reconciliation

    /// Desired effective gain for an app: 0 when muted, else its stored gain. Returns
    /// `nil` when the app needs no interception (unity + unmuted, no existing tap) so
    /// untouched apps keep the direct, zero-latency path.
    private func effectiveGain(for app: AudioApp) -> Float32? {
        let key = key(for: app)
        let effective = mutes.contains(key) ? 0.0 : (gains[key] ?? 1.0)
        if effective == 1.0, !engine.hasTap(for: app.id) { return nil }
        return Float32(effective)
    }

    private func reconcile() {
        guard permission.isAuthorized else { return }
        engine.reconcile(apps: processes.apps, effectiveGain: effectiveGain)
    }

    private func rebuildAll() {
        guard permission.isAuthorized else { return }
        engine.rebuildAll(apps: processes.apps, effectiveGain: effectiveGain)
    }

    /// When the user changes an app's volume/mute without permission yet, request it
    /// once, then reconcile so the change takes effect immediately on grant.
    private func ensurePermissionThenReconcile() {
        switch permission.status {
        case .authorized:
            reconcile()
        case .unknown:
            permission.request { [weak self] in self?.reconcile() }
        case .denied:
            break // UI shows guidance to enable it in System Settings.
        }
    }

    /// Called by the UI's "Grant Access" button.
    func requestPermission() {
        permission.request { [weak self] in self?.reconcile() }
    }
}
