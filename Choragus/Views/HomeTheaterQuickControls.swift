/// HomeTheaterQuickControls.swift — Night Mode / Dialog Enhancement in
/// Now Playing, for home-theatre zones only (#78). Other speakers reject
/// these `SetEQ` types, so the row stays hidden there.
import SwiftUI
import SonosKit

struct HomeTheaterQuickControls: View {
    @EnvironmentObject var sonosManager: SonosManager
    let group: SonosGroup

    @State private var nightMode = false
    @State private var dialogEnhancement = false
    /// Hidden until the speaker answers, rather than guessing a position.
    @State private var loaded = false

    /// Same signal the EQ button uses to pick which EQ surface to open.
    private var isHomeTheaterZone: Bool {
        sonosManager.htSatChannelMaps[group.coordinatorID] != nil
    }

    var body: some View {
        // Root must be a real view: a `Group` holding only a false `if`
        // collapses to `EmptyView` and the `.task` never runs.
        HStack(spacing: 12) {
            if isHomeTheaterZone && loaded {
                toggleButton(title: L10n.nightMode,
                             systemImage: "moon.stars",
                             isOn: $nightMode,
                             eqType: "NightMode")

                toggleButton(title: L10n.dialogEnhancement,
                             systemImage: "text.bubble",
                             isOn: $dialogEnhancement,
                             eqType: "DialogLevel")
            }
        }
        // Keyed on HT status too: the channel map is empty until the first
        // topology parse, so an id-only key would evaluate once and stop.
        .task(id: "\(group.coordinatorID)|\(isHomeTheaterZone)") { await load() }
    }

    /// Tinted while on, matching the button row above.
    private func toggleButton(title: String,
                              systemImage: String,
                              isOn: Binding<Bool>,
                              eqType: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
            apply(eqType: eqType, value: isOn.wrappedValue)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // Themed accent, not SwiftUI's system accent.
        .tint(isOn.wrappedValue ? (sonosManager.resolvedAccentColor ?? .accentColor) : nil)
    }

    private func apply(eqType: String, value: Bool) {
        guard let coordinator = group.coordinator else { return }
        Task {
            do {
                try await sonosManager.setEQ(device: coordinator,
                                             eqType: eqType,
                                             value: value ? 1 : 0)
            } catch {
                sonosDiagLog(.error, tag: "HT-EQ",
                             "SetEQ failed: \(error.localizedDescription)",
                             context: ["eqType": eqType, "room": coordinator.roomName])
            }
        }
    }

    private func load() async {
        loaded = false
        guard isHomeTheaterZone, let coordinator = group.coordinator else { return }
        // A fault means unsupported: treat as off rather than block the row.
        nightMode = (try? await sonosManager.getEQ(device: coordinator,
                                                   eqType: "NightMode")) == 1
        dialogEnhancement = (try? await sonosManager.getEQ(device: coordinator,
                                                           eqType: "DialogLevel")) == 1
        loaded = true
    }
}
