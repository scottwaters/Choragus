/// VolumeControlView.swift — Per-speaker volume sliders for grouped speakers.
///
/// Shown below the master volume when a group has multiple members.
/// Each speaker's volume is independently controllable. The pending spinner
/// uses a 300ms delay to avoid flashing on fast network responses.
import SwiftUI
import SonosKit

struct VolumeControlView: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup
    @Binding var speakerVolumes: [String: Double]
    @Binding var speakerMutes: [String: Bool]

    @State private var pendingSpeakers: Set<String> = []
    @State private var pendingTimers: [String: Task<Void, Never>] = [:]

    private var sortedMembers: [SonosDevice] {
        let coordID = group.coordinatorID
        return group.members.sorted { a, b in
            if a.id == coordID { return true }
            if b.id == coordID { return false }
            return a.roomName.localizedCaseInsensitiveCompare(b.roomName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Speaker Volumes")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            ForEach(sortedMembers, id: \.id) { member in
                HStack(spacing: 8) {
                    Button {
                        Task { await toggleMute(device: member) }
                    } label: {
                        Image(systemName: (speakerMutes[member.id] ?? false) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 16)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)

                    Text(member.roomName)
                        .font(.caption)
                        .frame(width: 80, alignment: .leading)
                        .lineLimit(1)

                    Slider(
                        value: Binding(
                            get: { speakerVolumes[member.id] ?? 0 },
                            set: { newVal in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    speakerVolumes[member.id] = newVal
                                }
                            }
                        ),
                        in: 0...100
                    ) { editing in
                        if !editing {
                            Task { await setVolume(device: member) }
                        }
                    }

                    Text("\(Int(speakerVolumes[member.id] ?? 0))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 24, alignment: .trailing)

                    if pendingSpeakers.contains(member.id) {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12)
                    } else {
                        Color.clear
                            .frame(width: 12)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 16)
    }

    private func setVolume(device: SonosDevice) async {
        let vol = Int(speakerVolumes[device.id] ?? 0)
        showPending(device.id)
        try? await sonosManager.setVolume(device: device, volume: vol)
        clearPending(device.id)
    }

    private func toggleMute(device: SonosDevice) async {
        let currentMute = speakerMutes[device.id] ?? false
        speakerMutes[device.id] = !currentMute
        showPending(device.id)
        try? await sonosManager.setMute(device: device, muted: !currentMute)
        clearPending(device.id)
    }

    /// Show spinner only if the operation takes longer than 300ms
    private func showPending(_ id: String) {
        pendingTimers[id]?.cancel()
        pendingTimers[id] = Task {
            try? await Task.sleep(for: .milliseconds(300))
            if !Task.isCancelled {
                pendingSpeakers.insert(id)
            }
        }
    }

    private func clearPending(_ id: String) {
        pendingTimers[id]?.cancel()
        pendingTimers[id] = nil
        pendingSpeakers.remove(id)
    }
}
