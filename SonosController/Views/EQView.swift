import SwiftUI
import SonosKit

struct EQView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup

    @State private var selectedDeviceID: String?
    @State private var bass: Double = 0
    @State private var treble: Double = 0
    @State private var loudness: Bool = false
    @State private var isLoading = true

    private var visibleMembers: [SonosDevice] {
        group.members.sorted { $0.roomName < $1.roomName }
    }

    private var selectedDevice: SonosDevice? {
        if let id = selectedDeviceID {
            return group.members.first { $0.id == id }
        }
        return group.coordinator
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if visibleMembers.count > 1 {
                HStack {
                    Text(L10n.eq)
                        .font(.headline)
                    Spacer()
                    Picker("", selection: $selectedDeviceID) {
                        ForEach(visibleMembers) { device in
                            Text(device.roomName).tag(Optional(device.id))
                        }
                    }
                    .frame(maxWidth: 160)
                    .onChange(of: selectedDeviceID) {
                        Task { await loadEQ() }
                    }
                }
            } else {
                Text("\(L10n.eq): \(selectedDevice?.roomName ?? "")")
                    .font(.headline)
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.bass)
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $bass, in: -10...10, step: 1) { editing in
                        if !editing { Task { await saveBass() } }
                    }
                    Text("\(Int(bass))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }

                HStack {
                    Text(L10n.treble)
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $treble, in: -10...10, step: 1) { editing in
                        if !editing { Task { await saveTreble() } }
                    }
                    Text("\(Int(treble))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }

                Toggle(L10n.loudness, isOn: $loudness)
                    .onChange(of: loudness) {
                        Task { await saveLoudness() }
                    }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 320, height: visibleMembers.count > 1 ? 240 : 220)
        .onAppear {
            selectedDeviceID = group.coordinatorID
            Task { await loadEQ() }
        }
    }

    private func loadEQ() async {
        guard let device = selectedDevice else { return }
        do {
            bass = Double(try await sonosManager.getBass(device: device))
            treble = Double(try await sonosManager.getTreble(device: device))
            loudness = try await sonosManager.getLoudness(device: device)
            isLoading = false
        } catch {
            sonosDebugLog("[EQ] Load EQ settings failed: \(error)")
        }
    }

    private func saveBass() async {
        guard let device = selectedDevice else { return }
        try? await sonosManager.setBass(device: device, bass: Int(bass))
    }

    private func saveTreble() async {
        guard let device = selectedDevice else { return }
        try? await sonosManager.setTreble(device: device, treble: Int(treble))
    }

    private func saveLoudness() async {
        guard let device = selectedDevice else { return }
        try? await sonosManager.setLoudness(device: device, enabled: loudness)
    }
}
