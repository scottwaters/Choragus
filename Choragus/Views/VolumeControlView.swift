/// VolumeControlView.swift — Per-speaker volume sliders for grouped speakers.
///
/// Shown below the master volume when a group has multiple members.
/// Layout: [mute] [name] [slider] [value] — all inline, slider fills remaining space.
/// Business logic is delegated to the parent via closures (SoC).
import SwiftUI
import SonosKit

struct VolumeControlView: View {
    let group: SonosGroup
    @Binding var speakerVolumes: [String: Double]
    @Binding var speakerMutes: [String: Bool]
    var accentColor: Color = .accentColor
    var onSetVolume: ((SonosDevice, Int) async -> Void)?
    var onToggleMute: ((SonosDevice, Bool) async -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?

    @State private var draggingSpeaker: String?

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
            Text(L10n.speakerVolumes)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, UILayout.horizontalPadding)
                .padding(.top, 8)

            ForEach(sortedMembers, id: \.id) { member in
                HStack(spacing: 8) {
                    Button {
                        let newMuted = !(speakerMutes[member.id] ?? false)
                        speakerMutes[member.id] = newMuted
                        Task { await onToggleMute?(member, newMuted) }
                    } label: {
                        Image(systemName: (speakerMutes[member.id] ?? false) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 20)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)

                    Text(member.roomName)
                        .font(.caption)
                        .lineLimit(1)
                        .frame(minWidth: UILayout.speakerNameMinWidth, alignment: .leading)
                        .layoutPriority(-1)

                    SliderWithPopup(
                        value: Binding(
                            get: { speakerVolumes[member.id] ?? 0 },
                            set: { newVal in
                                speakerVolumes[member.id] = newVal
                            }
                        ),
                        range: 0...100
                    ) { editing in
                        draggingSpeaker = editing ? member.id : nil
                        onDragStateChanged?(editing)
                        if !editing {
                            let vol = Int(speakerVolumes[member.id] ?? 0)
                            Task { await onSetVolume?(member, vol) }
                        }
                    }

                    Text("\(Int(speakerVolumes[member.id] ?? 0))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: UILayout.volumeLabelWidth, alignment: .trailing)
                }
                .padding(.horizontal, UILayout.horizontalPadding)
            }
        }
        .padding(.bottom, 16)
        .tint(accentColor)
    }
}
