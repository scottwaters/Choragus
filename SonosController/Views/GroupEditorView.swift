/// GroupEditorView.swift — Speaker grouping editor sheet.
///
/// Uses optimistic updates: checkmarks flip immediately on tap, then SOAP calls
/// run in the background. If the call fails, the optimistic state is reverted.
/// A 1-second delay before topology refresh gives the speaker time to process
/// the grouping change before we query the new state.
import SwiftUI
import SonosKit

struct GroupEditorView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @Environment(\.dismiss) private var dismiss

    let initialGroup: SonosGroup
    @State private var pendingDeviceID: String?
    // Tracks group membership locally for instant UI — synced with server on topology refresh
    @State private var optimisticMemberIDs: Set<String>

    init(initialGroup: SonosGroup) {
        self.initialGroup = initialGroup
        self._optimisticMemberIDs = State(initialValue: Set(initialGroup.members.map(\.id)))
    }

    private var currentGroup: SonosGroup? {
        sonosManager.groups.first { $0.coordinatorID == initialGroup.coordinatorID }
    }

    private var availableDevices: [SonosDevice] {
        var result: [SonosDevice] = []
        var seen = Set<String>()
        for g in sonosManager.groups {
            for member in g.members {
                if !seen.contains(member.id) {
                    seen.insert(member.id)
                    result.append(member)
                }
            }
        }
        let coordID = initialGroup.coordinatorID
        return result.sorted { a, b in
            if a.id == coordID { return true }
            if b.id == coordID { return false }
            return a.roomName.localizedCaseInsensitiveCompare(b.roomName) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.groupSpeakers)
                .font(.headline)

            Text("\(L10n.tapToAddOrRemove) \"\(currentGroup?.name ?? initialGroup.name)\"")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(availableDevices, id: \.id) { device in
                        let isMember = optimisticMemberIDs.contains(device.id)
                        let isCoordinator = device.id == initialGroup.coordinatorID
                        let isPending = pendingDeviceID == device.id
                        let otherGroupName = groupName(for: device)

                        HStack {
                            if isPending {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 20)
                            } else {
                                Image(systemName: isMember ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isMember ? Color.accentColor : .secondary)
                                    .frame(width: 20)
                            }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.roomName)
                                    .font(.body)

                                if isCoordinator {
                                    Text(L10n.coordinator)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                } else if let otherName = otherGroupName, !isMember {
                                    Text("\(L10n.inGroup): \(otherName)")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }

                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard !isCoordinator, pendingDeviceID == nil else { return }
                            Task { await toggleMembership(device: device, isMember: isMember) }
                        }
                        .opacity(isCoordinator ? 0.5 : (isPending ? 0.6 : 1))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 4)
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button(L10n.groupAll) {
                    Task { await groupAll() }
                }
                .controlSize(.small)
                .disabled(pendingDeviceID != nil)

                Button(L10n.ungroupAll) {
                    Task { await ungroupAll() }
                }
                .controlSize(.small)
                .disabled(pendingDeviceID != nil)

                Spacer()

                Button(L10n.done) { dismiss() }
                    .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 360, height: 480)
        .onChange(of: sonosManager.groups) {
            // Sync optimistic state with actual topology when it catches up
            if let live = currentGroup {
                optimisticMemberIDs = Set(live.members.map(\.id))
            }
        }
    }

    private func groupAll() async {
        guard let coordinator = currentGroup?.coordinator ?? initialGroup.coordinator else { return }
        pendingDeviceID = "all"
        let nonMembers = availableDevices.filter {
            $0.id != coordinator.id && !optimisticMemberIDs.contains($0.id)
        }
        for device in nonMembers {
            optimisticMemberIDs.insert(device.id)
        }
        for device in nonMembers {
            do {
                try await sonosManager.joinGroup(device: device, toCoordinator: coordinator)
            } catch {
                // Grouping failed — will continue with remaining devices
            }
        }
        try? await Task.sleep(for: .seconds(Timing.groupRefreshDelay))
        if let dev = currentGroup?.coordinator ?? initialGroup.coordinator {
            await sonosManager.refreshTopology(from: dev)
        }
        pendingDeviceID = nil
    }

    private func ungroupAll() async {
        guard let coordinator = currentGroup?.coordinator ?? initialGroup.coordinator else { return }
        pendingDeviceID = "all"
        let members = availableDevices.filter {
            $0.id != coordinator.id && optimisticMemberIDs.contains($0.id)
        }
        optimisticMemberIDs = [coordinator.id]
        for device in members {
            do {
                try await sonosManager.ungroupDevice(device)
            } catch {
                // Ungrouping failed — will continue with remaining devices
            }
        }
        try? await Task.sleep(for: .seconds(Timing.groupRefreshDelay))
        await sonosManager.refreshTopology(from: coordinator)
        pendingDeviceID = nil
    }

    /// Returns the name of the group this device belongs to, if it's in a different group
    /// with multiple members (i.e. actively grouped elsewhere). Returns nil if standalone.
    private func groupName(for device: SonosDevice) -> String? {
        for g in sonosManager.groups {
            if g.coordinatorID == initialGroup.coordinatorID { continue }
            if g.members.contains(where: { $0.id == device.id }) && g.members.count > 1 {
                return g.name
            }
        }
        return nil
    }

    private func toggleMembership(device: SonosDevice, isMember: Bool) async {
        pendingDeviceID = device.id

        // Optimistic update — flip the checkmark immediately
        if isMember {
            optimisticMemberIDs.remove(device.id)
        } else {
            optimisticMemberIDs.insert(device.id)
        }

        do {
            if isMember {
                try await sonosManager.ungroupDevice(device)
            } else {
                guard let coordinator = currentGroup?.coordinator ?? initialGroup.coordinator else {
                    pendingDeviceID = nil
                    return
                }
                try await sonosManager.joinGroup(device: device, toCoordinator: coordinator)
            }

            // The speaker may not have updated its topology yet.
            // Wait briefly then refresh again to catch the change.
            try? await Task.sleep(for: .seconds(Timing.groupRefreshDelay))
            if let dev = currentGroup?.coordinator ?? initialGroup.coordinator {
                await sonosManager.refreshTopology(from: dev)
            }
        } catch {
            // Revert optimistic state on failure
            if isMember {
                optimisticMemberIDs.insert(device.id)
            } else {
                optimisticMemberIDs.remove(device.id)
            }
            // Grouping change failed — optimistic state reverted above
        }

        pendingDeviceID = nil
    }
}
