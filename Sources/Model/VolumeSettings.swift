import Foundation

/// Per-app volume/mute persistence, keyed by the same stable identity `AppMixerStore`
/// uses (bundle ID, else `pid:<n>`). Settings are reapplied on launch and whenever an
/// app reappears, since the key is stable across launches for bundle-ID'd apps.
enum VolumeSettings {
    private static let gainsKey = "perAppGains"
    private static let mutesKey = "perAppMutes"
    private static var defaults: UserDefaults { .standard }

    static func loadGains() -> [String: Double] {
        (defaults.dictionary(forKey: gainsKey) as? [String: Double]) ?? [:]
    }

    static func saveGains(_ gains: [String: Double]) {
        // Don't persist unity gains — keeps the store small and avoids stale keys.
        let pruned = gains.filter { $0.value != 1.0 }
        defaults.set(pruned, forKey: gainsKey)
    }

    static func loadMutes() -> Set<String> {
        Set(defaults.stringArray(forKey: mutesKey) ?? [])
    }

    static func saveMutes(_ mutes: Set<String>) {
        defaults.set(Array(mutes), forKey: mutesKey)
    }
}
