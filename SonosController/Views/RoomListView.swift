/// RoomListView.swift — Sidebar showing Sonos groups (rooms) with playing indicators.
///
/// Polls transport state every 5 seconds to show animated sound waves next to
/// actively playing groups. Handles topology changes by re-validating the selection
/// (e.g. if a grouped speaker splits, the selection follows the coordinator).
import SwiftUI
import SonosKit

struct RoomListView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @Binding var selectedGroupID: String?

    @State private var playingGroupIDs: Set<String> = []
    @State private var statusTask: Task<Void, Never>?

    private let iconColumnWidth: CGFloat = 54

    var body: some View {
        ScrollViewReader { proxy in
            List(sonosManager.groups, selection: $selectedGroupID) { group in
                let isPlaying = playingGroupIDs.contains(group.id)

                if group.members.count <= 1 {
                    HStack(spacing: 8) {
                        speakerWithWaves(playing: isPlaying, grouped: false)
                            .frame(width: iconColumnWidth)

                        Text(group.coordinator?.roomName ?? group.name)
                            .font(.body)
                    }
                    .padding(.vertical, 4)
                    .tag(group.id)
                    .id(group.id)
                } else {
                    let coordinator = group.coordinator
                    let others = group.members
                        .filter { $0.id != group.coordinatorID }
                        .sorted { $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            speakerWithWaves(playing: isPlaying, grouped: true)
                                .frame(width: iconColumnWidth)

                            Text(coordinator?.roomName ?? group.name)
                                .font(.body)
                                .fontWeight(.medium)
                        }

                        ForEach(others, id: \.id) { member in
                            Text(member.roomName)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .padding(.leading, iconColumnWidth + 18)
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(group.id)
                    .id(group.id)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Rooms")
            .onAppear { startStatusPolling() }
            .onDisappear { stopStatusPolling() }
            .onChange(of: sonosManager.groups) {
                validateAndScrollSelection(proxy: proxy)
            }
            .onChange(of: selectedGroupID) {
                scrollToSelection(proxy: proxy)
            }
        }
    }

    // MARK: - Speaker Icon with Waves

    private func speakerWithWaves(playing: Bool, grouped: Bool) -> some View {
        HStack(spacing: 2) {
            if playing {
                SoundWaves()
                    .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .frame(width: 8, height: 14)
                    .scaleEffect(x: -1, y: 1)
            } else {
                Spacer().frame(width: 8)
            }

            Image(systemName: grouped ? "hifispeaker.2.fill" : "hifispeaker.fill")
                .font(.system(size: 16))
                .foregroundStyle(grouped ? Color.accentColor : .secondary)
        }
    }

    // MARK: - Status Polling

    private func startStatusPolling() {
        stopStatusPolling()
        statusTask = Task {
            while !Task.isCancelled {
                await pollPlayingStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func stopStatusPolling() {
        statusTask?.cancel()
        statusTask = nil
    }

    private func pollPlayingStatus() async {
        var playing = Set<String>()
        for group in sonosManager.groups {
            do {
                let state = try await sonosManager.getTransportState(group: group)
                if state.isActive {
                    playing.insert(group.id)
                }
            } catch {}
        }
        playingGroupIDs = playing
    }

    // MARK: - Selection

    /// When topology changes, the selected group ID may no longer exist.
    /// Try to find the new group containing the same device, otherwise fall back to first.
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
