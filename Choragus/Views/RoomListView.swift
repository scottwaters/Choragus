/// RoomListView.swift — Custom sidebar showing Sonos groups (rooms) with playing indicators.
///
/// Uses a custom ScrollView instead of List to avoid the AppKit NSTableView blue
/// selection flash. Selection is handled manually with accent-colored backgrounds.
import SwiftUI
import SonosKit

struct RoomListView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @Binding var selectedGroupID: String?
    @State private var showGroupEditorFor: SonosGroup?

    private let iconColumnWidth: CGFloat = 34

    private var playingCoordinatorIDs: Set<String> {
        Set(sonosManager.groupTransportStates.filter { $0.value.isActive }.map { $0.key })
    }

    private var selectionColor: Color {
        sonosManager.resolvedAccentColor ?? .accentColor
    }

    /// Groups partitioned by household, ordered S2 → S1 → Unknown.
    /// Groups with no visible members are excluded, and households whose only
    /// groups are empty are dropped entirely so no orphan header appears.
    /// When only a single household remains, callers render without the header.
    private var sections: [HouseholdSection] {
        var buckets: [String: HouseholdSection] = [:]
        for group in sonosManager.groups where !group.members.isEmpty {
            let key = group.householdID ?? ""
            if buckets[key] == nil {
                buckets[key] = HouseholdSection(
                    householdID: key,
                    version: group.systemVersion,
                    groups: []
                )
            }
            // Upgrade the section's version if a later group has better signal
            if buckets[key]?.version == .unknown, group.systemVersion != .unknown {
                buckets[key]?.version = group.systemVersion
            }
            buckets[key]?.groups.append(group)
        }
        let order: [SonosSystemVersion: Int] = [.s2: 0, .s1: 1, .unknown: 2]
        return buckets.values
            .filter { !$0.groups.isEmpty }
            .map { section -> HouseholdSection in
                var s = section
                s.groups.sort { $0.name < $1.name }
                return s
            }
            .sorted { lhs, rhs in
                let lo = order[lhs.version] ?? 3
                let ro = order[rhs.version] ?? 3
                if lo != ro { return lo < ro }
                return lhs.householdID < rhs.householdID
            }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 1) {
                    let allSections = sections
                    let showHeaders = allSections.count > 1
                    ForEach(Array(allSections.enumerated()), id: \.element.householdID) { index, section in
                        if showHeaders {
                            if index > 0 {
                                Divider()
                                    .padding(.vertical, 4)
                            }
                            Text(section.version.displayLabel)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.top, index == 0 ? 4 : 0)
                                .padding(.bottom, 2)
                        }

                        ForEach(section.groups) { group in
                            let isPlaying = playingCoordinatorIDs.contains(group.coordinatorID)
                            let isSelected = selectedGroupID == group.id

                            Button {
                                selectedGroupID = group.id
                            } label: {
                                roomRow(group: group, isPlaying: isPlaying, isSelected: isSelected)
                            }
                            .buttonStyle(.plain)
                            .id(group.id)
                            .contextMenu { roomContextMenu(group: group, isPlaying: isPlaying) }
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 4)
            }
            .clipped()
            .navigationTitle(L10n.rooms)
            .onChange(of: sonosManager.groups) {
                validateAndScrollSelection(proxy: proxy)
            }
            .onChange(of: selectedGroupID) {
                scrollToSelection(proxy: proxy)
            }
            .sheet(item: $showGroupEditorFor) { group in
                GroupEditorView(initialGroup: group)
                    .environmentObject(sonosManager)
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func roomContextMenu(group: SonosGroup, isPlaying: Bool) -> some View {
        // Play / Pause
        if isPlaying {
            Button(L10n.pause) {
                Task { await ErrorHandler.shared.handleAsync("PLAYBACK") { try await sonosManager.pause(group: group) } }
            }
        } else {
            Button(L10n.play) {
                Task { await ErrorHandler.shared.handleAsync("PLAYBACK") { try await sonosManager.play(group: group) } }
            }
        }

        Divider()

        // Mute / Unmute
        let allMuted = group.members.allSatisfy { sonosManager.deviceMutes[$0.id] == true }
        Button(allMuted ? L10n.unmute : L10n.mute) {
            Task {
                for member in group.members {
                    try? await sonosManager.setMute(device: member, muted: !allMuted) // fire-and-forget OK
                }
            }
        }

        Divider()

        // Grouping
        Button(L10n.editGroupEllipsis) {
            showGroupEditorFor = group
        }

        if group.members.count > 1 {
            Button(L10n.ungroupAll) {
                Task {
                    for member in group.members where member.id != group.coordinatorID {
                        try? await sonosManager.ungroupDevice(member) // fire-and-forget OK
                    }
                }
            }
        }

        // Home Theater EQ (only for HT zones)
        if sonosManager.htSatChannelMaps[group.coordinatorID] != nil {
            Divider()
            Button(L10n.homeTheaterEQEllipsis) {
                WindowManager.shared.openHomeTheaterEQ()
            }
        }
    }

    // MARK: - Room Row

    @ViewBuilder
    private func roomRow(group: SonosGroup, isPlaying: Bool, isSelected: Bool) -> some View {
        if group.members.count <= 1 {
            HStack(spacing: 6) {
                speakerWithWaves(playing: isPlaying, grouped: false)
                    .frame(width: iconColumnWidth)

                Text(group.coordinator?.roomName ?? group.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(isSelected ? selectionColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        } else {
            let coordinator = group.coordinator
            let others = group.members
                .filter { $0.id != group.coordinatorID }
                .sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    speakerWithWaves(playing: isPlaying, grouped: true)
                        .frame(width: iconColumnWidth)

                    Text(coordinator?.roomName ?? group.name)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isSelected ? .white : .primary)

                    Spacer(minLength: 0)
                }

                ForEach(others, id: \.id) { member in
                    Text(member.roomName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                        .padding(.leading, iconColumnWidth + 6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(isSelected ? selectionColor : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Speaker Icon with Waves

    /// Icon colors always use the user's chosen zone colors, regardless of selection state.
    private func speakerWithWaves(playing: Bool, grouped: Bool) -> some View {
        HStack(spacing: 2) {
            if playing {
                AnimatedSoundWaves()
                    .frame(width: 8, height: 14)
                    .scaleEffect(x: -1, y: 1)
            } else {
                Spacer().frame(width: 8)
            }

            Image(systemName: grouped ? "hifispeaker.2.fill" : "hifispeaker.fill")
                .font(.system(size: 16))
                .foregroundStyle(playing ? sonosManager.resolvedPlayingZoneColor : sonosManager.resolvedInactiveZoneColor)
        }
    }

    // MARK: - Selection

    private func validateAndScrollSelection(proxy: ScrollViewProxy) {
        if let selectedID = selectedGroupID,
           !sonosManager.groups.contains(where: { $0.id == selectedID }) {
            if let match = sonosManager.groups.first(where: { group in
                group.members.contains(where: { $0.id == selectedID })
            }) {
                selectedGroupID = match.id
            } else {
                selectedGroupID = sonosManager.groups.first?.id
            }
        }
        scrollToSelection(proxy: proxy)
    }

    private func scrollToSelection(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let id = selectedGroupID {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            } else if let first = sonosManager.groups.first {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
    }
}

/// Partition of rooms belonging to one Sonos household (S1 or S2 system).
private struct HouseholdSection {
    let householdID: String
    var version: SonosSystemVersion
    var groups: [SonosGroup]
}

/// Animated sound waves that gently pulse opacity
private struct AnimatedSoundWaves: View {
    @State private var pulse = false

    var body: some View {
        SoundWaves()
            .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            .foregroundStyle(.primary.opacity(pulse ? 0.8 : 0.35))
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// Custom shape drawing two concentric arcs to represent sound waves emanating from a speaker
struct SoundWaves: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let origin = CGPoint(x: 0, y: rect.midY)
        let radii: [CGFloat] = [
            rect.height * 0.45,
            rect.height * 0.75,
        ]
        for radius in radii {
            let startAngle = Angle.degrees(-45)
            let startX = origin.x + radius * cos(startAngle.radians)
            let startY = origin.y + radius * sin(startAngle.radians)
            path.move(to: CGPoint(x: startX, y: startY))
            path.addArc(center: origin, radius: radius,
                        startAngle: startAngle, endAngle: .degrees(45),
                        clockwise: false)
        }
        return path
    }
}
