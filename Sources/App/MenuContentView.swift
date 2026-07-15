import AppKit
import SwiftUI

struct MenuContentView: View {
    @Bindable var store: AppMixerStore
    let updater: AppUpdater
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            MasterVolumeSection(master: store.master)

            Divider()

            appsSection

            if store.permission.status != .authorized {
                permissionBanner
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.vertical.3")
            Text("Swara").font(.headline)
            Text(appVersion).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(v)"
    }

    @ViewBuilder
    private var appsSection: some View {
        Text("Applications")
            .font(.caption).foregroundStyle(.secondary)

        if store.processes.apps.isEmpty {
            Text("No apps are playing audio.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 10) {
                ForEach(store.processes.apps) { app in
                    AppVolumeRow(app: app, store: store)
                }
            }
        }
    }

    @ViewBuilder
    private var permissionBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Per-app volume needs audio-capture access.")
                    .font(.caption)
                if store.permission.status == .denied {
                    Button("Open System Settings") { openAudioCaptureSettings() }
                        .font(.caption)
                } else {
                    Button("Grant Access") { store.requestPermission() }
                        .font(.caption)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { launchAtLogin = $0; LaunchAtLogin.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .font(.caption)

            Spacer()

            Button("Check for Updates…") { updater.checkForUpdates() }
                .font(.caption)

            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    private func openAudioCaptureSettings() {
        // Privacy & Security → System Audio Recording pane.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Master volume + mute + output-device picker.
struct MasterVolumeSection: View {
    @Bindable var master: MasterVolumeController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: master.toggleMute) {
                    Image(systemName: master.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(master.muted ? "Unmute" : "Mute")

                Slider(
                    value: Binding(get: { master.volume }, set: { master.setVolume($0) }),
                    in: 0...1
                )
                .disabled(!master.volumeControllable || master.muted)

                Text("\(Int((master.muted ? 0 : master.volume) * 100))%")
                    .font(.caption).monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }

            DevicePickerView(master: master)
        }
    }
}
