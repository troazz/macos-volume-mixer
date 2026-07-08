import CoreAudio
import SwiftUI

/// Output-device chooser bound to the current default output device.
struct DevicePickerView: View {
    @Bindable var master: MasterVolumeController

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hifispeaker.fill")
                .foregroundStyle(.secondary)
                .frame(width: 18)

            Picker("Output", selection: selection) {
                ForEach(master.devices) { device in
                    Text(device.name).tag(Optional(device.id))
                }
            }
            .labelsHidden()
        }
    }

    private var selection: Binding<AudioObjectID?> {
        Binding(
            get: { master.defaultDeviceID },
            set: { newID in
                if let newID, let device = master.devices.first(where: { $0.id == newID }) {
                    master.selectDevice(device)
                }
            }
        )
    }
}
