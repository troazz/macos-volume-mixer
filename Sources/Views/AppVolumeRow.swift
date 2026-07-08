import SwiftUI

/// One row in the mixer: app icon, name, mute toggle, volume slider, percentage.
struct AppVolumeRow: View {
    let app: AudioApp
    @Bindable var store: AppMixerStore

    /// ±6% magnetic "stick" zone around 100% so unity gain is easy to land on.
    private static let unitySnapWindow: Double = 0.06

    private var isMuted: Bool { store.isMuted(for: app) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                icon
                Text(app.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(0)   // name yields (truncates) before controls shrink

                // Media controls sit next to the name, only for the now-playing source.
                if let transport = store.transport(for: app) {
                    transportControls(transport)
                        .fixedSize()            // keep controls at full size
                        .padding(.leading, 8)   // breathing room from the name
                        .layoutPriority(1)
                }

                Spacer(minLength: 8)

                if !store.isDefault(for: app) {
                    Button {
                        store.reset(for: app)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Reset to 100%")
                }
                Text("\(Int((isMuted ? 0 : store.volume(for: app)) * 100))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            HStack(spacing: 8) {
                Button {
                    store.toggleMute(for: app)
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(isMuted ? "Unmute" : "Mute")

                Slider(
                    value: Binding(
                        get: { store.volume(for: app) },
                        set: { raw in
                            let snapped = abs(raw - 1.0) < Self.unitySnapWindow ? 1.0 : raw
                            store.setVolume(snapped, for: app)
                        }
                    ),
                    in: 0...AppMixerStore.maxGain
                )
                .disabled(isMuted)
            }
        }
    }

    /// Compact inline play/pause/next/previous for the current now-playing source.
    @ViewBuilder
    private func transportControls(_ transport: NowPlaying) -> some View {
        HStack(spacing: 10) {
            Button { store.previousTrack(for: app) } label: {
                Image(systemName: "backward.fill")
            }
            .help("Previous")

            Button { store.playPause(for: app) } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 12)
            }
            .help(transport.isPlaying ? "Pause" : "Play")

            Button { store.nextTrack(for: app) } label: {
                Image(systemName: "forward.fill")
            }
            .help("Next")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .imageScale(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
        )
    }

    @ViewBuilder
    private var icon: some View {
        if let nsImage = app.icon {
            Image(nsImage: nsImage).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "app.dashed").frame(width: 18, height: 18)
        }
    }
}
