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
    @State private var editingSpeakerID: String?

    private var sortedMembers: [SonosDevice] {
        let coordID = group.coordinatorID
        return group.members.sorted { a, b in
            if a.id == coordID { return true }
            if b.id == coordID { return false }
            return a.roomName.localizedCaseInsensitiveCompare(b.roomName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .sliderCenter, spacing: 6) {
            Text(L10n.speakerVolumes)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, UILayout.horizontalPadding)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

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
                        .fixedSize(horizontal: true, vertical: false)

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
                    .frame(maxWidth: 300)
                    .alignmentGuide(.sliderCenter) { d in d[HorizontalAlignment.center] }

                    Text("\(Int(speakerVolumes[member.id] ?? 0))")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: UILayout.volumeLabelWidth, alignment: .trailing)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { editingSpeakerID = member.id }
                        .help(L10n.doubleClickToTypeValue)
                        .popover(
                            isPresented: Binding(
                                get: { editingSpeakerID == member.id },
                                set: { if !$0 { editingSpeakerID = nil } }
                            ),
                            arrowEdge: .top
                        ) {
                            VolumeNumberInputPopover(
                                initialValue: Int(speakerVolumes[member.id] ?? 0),
                                onCommit: { newVal in
                                    speakerVolumes[member.id] = Double(newVal)
                                    Task { await onSetVolume?(member, newVal) }
                                    editingSpeakerID = nil
                                },
                                onCancel: { editingSpeakerID = nil }
                            )
                        }
                }
                .padding(.horizontal, UILayout.horizontalPadding)
            }
        }
        .padding(.bottom, 16)
        .tint(accentColor)
    }
}
