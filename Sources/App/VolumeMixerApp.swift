import SwiftUI

@main
struct VolumeMixerApp: App {
    @State private var store = AppMixerStore()
    private let updater = AppUpdater()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(store: store, updater: updater)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    /// Reflect master mute/level in the menu-bar glyph.
    private var menuBarSymbol: String {
        if store.master.muted { return "speaker.slash.fill" }
        switch store.master.volume {
        case ..<0.01: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default:      return "speaker.wave.3.fill"
        }
    }
}
