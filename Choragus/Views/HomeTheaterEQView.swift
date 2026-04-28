/// HomeTheaterEQView.swift — EQ settings for home theater zones (sub, surrounds).
///
/// Follows the Sonos app pattern: zone picker + tabbed EQ/Sub/Surrounds controls.
/// All settings are sent to the coordinator (soundbar) via GetEQ/SetEQ SOAP calls.
import SwiftUI
import SonosKit

struct HomeTheaterEQView: View {
    @EnvironmentObject var sonosManager: SonosManager

    @State private var selectedZoneID: String?
    @State private var selectedTab = 0

    // EQ
    @State private var bass: Double = 0
    @State private var treble: Double = 0
    @State private var loudness = false
    @State private var nightMode = false
    @State private var dialogLevel = false

    // Sub
    @State private var subEnabled = true
    @State private var subGain: Double = 0
    @State private var subPolarity = false

    // Surrounds
    @State private var surroundEnabled = true
    @State private var surroundLevel: Double = 0
    @State private var musicSurroundLevel: Double = 0
    @State private var surroundMode = 1 // 1=Full, 0=Ambient

    @State private var isLoading = true

    private var zones: [HomeTheaterZone] {
        sonosManager.homeTheaterZones
    }

    private var selectedZone: HomeTheaterZone? {
        guard let id = selectedZoneID else { return zones.first }
        return zones.first { $0.id == id }
    }

    private var coordinator: SonosDevice? {
        guard let zone = selectedZone else { return nil }
        return sonosManager.devices[zone.coordinatorID]
    }

    var body: some View {
        VStack(spacing: 0) {
            if zones.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "hifispeaker.and.homepodmini")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text(L10n.noHomeTheaterZones)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(L10n.homeTheaterConnectHelp)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Zone picker
                HStack {
                    Text(L10n.homeTheaterEQTitle)
                        .font(.title3)
                        .fontWeight(.semibold)

                    Spacer()

                    if zones.count > 1 {
                        Picker("", selection: $selectedZoneID) {
                            ForEach(zones) { zone in
                                Text(zone.description).tag(Optional(zone.id))
                            }
                        }
                        .frame(maxWidth: 250)
                        .onChange(of: selectedZoneID) {
                            Task { await loadAll() }
                        }
                    } else if let zone = zones.first {
                        Text(zone.description)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 12)

                // Tabs
                Picker("", selection: $selectedTab) {
                    Text(L10n.eqTab).tag(0)
                    if selectedZone?.hasSub == true { Text(L10n.subTab).tag(1) }
                    if selectedZone?.hasSurrounds == true { Text(L10n.surroundsTab).tag(2) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .padding(.bottom, 16)

                Divider()

                // Tab content
                ScrollView {
                    VStack(spacing: 20) {
                        switch selectedTab {
                        case 0: eqTab
                        case 1: subTab
                        case 2: surroundsTab
                        default: eqTab
                        }
                    }
                    .padding(28)
                }
            }
        }
        .frame(width: 480, height: 420)
        .onAppear {
            selectedZoneID = zones.first?.id
            Task { await loadAll() }
        }
    }

    // MARK: - EQ Tab

    private var eqTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.homeTheaterTrebleBassHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            sliderRow(L10n.bass, value: $bass, range: -10...10) {
                Task { guard let d = self.coordinator else { return }; try? await sonosManager.setEQ(device: d, eqType: "Bass", value: Int(bass)) }
            }

            sliderRow(L10n.treble, value: $treble, range: -10...10) {
                Task { guard let d = self.coordinator else { return }; try? await sonosManager.setEQ(device: d, eqType: "Treble", value: Int(treble)) }
            }

            Toggle(L10n.loudness, isOn: $loudness)
                .onChange(of: loudness) {
                    guard let d = coordinator else { return }
                    Task { try? await sonosManager.setLoudness(device: d, enabled: loudness) }
                }

            Divider()

            Toggle(L10n.nightMode, isOn: $nightMode)
                .onChange(of: nightMode) {
                    guard let d = coordinator else { return }
                    Task { guard let d = self.coordinator else { return }; try? await sonosManager.setEQ(device: d, eqType: "NightMode", value: nightMode ? 1 : 0) }
                }

            Toggle(L10n.dialogEnhancement, isOn: $dialogLevel)
                .onChange(of: dialogLevel) {
                    guard let d = coordinator else { return }
                    Task { guard let d = self.coordinator else { return }; try? await sonosManager.setEQ(device: d, eqType: "DialogLevel", value: dialogLevel ? 1 : 0) }
                }

            Spacer()

            HStack {
                Spacer()
                Button(L10n.reset) { Task { await resetEQ() } }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Sub Tab

    private var subTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle(L10n.subOn, isOn: $subEnabled)
                .onChange(of: subEnabled) {
                    guard let d = coordinator else { return }
                    Task { guard let d = self.coordinator else { return }; try? await sonosManager.setEQ(device: d, eqType: "SubEnable", value: subEnabled ? 1 : 0) }
                }

            sliderRow(L10n.subLevel, value: $subGain, range: -15...15) {
                Task { guard let d = self.coordinator else { return }; try? await sonosManager.setEQ(device: d, eqType: "SubGain", value: Int(subGain)) }
            }
            .disabled(!subEnabled)

            Toggle(L10n.placementAdjustment, isOn: $subPolarity)
                .onChange(of: subPolarity) {
                    guard let d = coordinator else { return }
                    Task { guard let d = self.coordinator else { return }; try? await sonosManager.setEQ(device: d, eqType: "SubPolarity", value: subPolarity ? 1 : 0) }
                }
                .disabled(!subEnabled)

            Spacer()

            HStack {
                Spacer()
                Button(L10n.reset) { Task { await resetSub() } }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Surrounds Tab

    private var surroundsTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Toggle(L10n.surroundsOn, isOn: $surroundEnabled)
                .onChange(of: surroundEnabled) {
                    guard let d = coordinator else { return }
                    Task { guard let d = self.coordinator else { return }; try? await sonosManager.setEQ(device: d, eqType: "SurroundEnable", value: surroundEnabled ? 1 : 0) }
                }

            Group {
                sliderRow(L10n.tvLevel, value: $surroundLevel, range: -15...15) {
                    Task { guard let d = self.coordinator else { return }; try? await sonosManager.setEQ(device: d, eqType: "SurroundLevel", value: Int(surroundLevel)) }
                }

                sliderRow(L10n.musicLevel, value: $musicSurroundLevel, range: -15...15) {
                    Task { guard let d = self.coordinator else { return }; try? await sonosManager.setEQ(device: d, eqType: "MusicSurroundLevel", value: Int(musicSurroundLevel)) }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.musicPlayback)
                        .font(.subheadline)
                    Text(L10n.homeTheaterSurroundHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $surroundMode) {
                        Text(L10n.surroundModeFull).tag(1)
                        Text(L10n.surroundModeAmbient).tag(0)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    .onChange(of: surroundMode) {
                        guard let d = coordinator else { return }
                        Task { guard let d = self.coordinator else { return }; try? await sonosManager.setEQ(device: d, eqType: "SurroundMode", value: surroundMode) }
                    }
                }
            }
            .disabled(!surroundEnabled)

            Spacer()

            HStack {
                Spacer()
                Button(L10n.reset) { Task { await resetSurrounds() } }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Helpers

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, onCommit: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 100, alignment: .leading)
            Text("-")
                .font(.caption)
                .foregroundStyle(.secondary)
            Slider(value: value, in: range, step: 1) { editing in
                if !editing { onCommit() }
            }
            Text("+")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(Int(value.wrappedValue))")
                .font(.caption)
                .monospacedDigit()
                .frame(width: 28, alignment: .trailing)
        }
    }

    // MARK: - Load / Reset

    private func loadAll() async {
        guard let d = coordinator else { return }
        isLoading = true
        do {
            bass = Double(try await sonosManager.getBass(device: d))
            treble = Double(try await sonosManager.getTreble(device: d))
            loudness = try await sonosManager.getLoudness(device: d)
            nightMode = (try? await sonosManager.getEQ(device: d, eqType: "NightMode")) == 1
            dialogLevel = (try? await sonosManager.getEQ(device: d, eqType: "DialogLevel")) == 1
            subEnabled = (try? await sonosManager.getEQ(device: d, eqType: "SubEnable")) != 0
            subGain = Double((try? await sonosManager.getEQ(device: d, eqType: "SubGain")) ?? 0)
            subPolarity = (try? await sonosManager.getEQ(device: d, eqType: "SubPolarity")) == 1
            surroundEnabled = (try? await sonosManager.getEQ(device: d, eqType: "SurroundEnable")) != 0
            surroundLevel = Double((try? await sonosManager.getEQ(device: d, eqType: "SurroundLevel")) ?? 0)
            musicSurroundLevel = Double((try? await sonosManager.getEQ(device: d, eqType: "MusicSurroundLevel")) ?? 0)
            surroundMode = (try? await sonosManager.getEQ(device: d, eqType: "SurroundMode")) ?? 1
        } catch {
            sonosDebugLog("[EQ] Home theater EQ load failed: \(error)")
        }
        isLoading = false
    }

    private func resetEQ() async {
        guard let d = coordinator else { return }
        bass = 0; treble = 0; loudness = true; nightMode = false; dialogLevel = false
        try? await sonosManager.setBass(device: d, bass: 0)
        try? await sonosManager.setTreble(device: d, treble: 0)
        try? await sonosManager.setLoudness(device: d, enabled: true)
        try? await sonosManager.setEQ(device: d, eqType: "NightMode", value: 0)
        try? await sonosManager.setEQ(device: d, eqType: "DialogLevel", value: 0)
    }

    private func resetSub() async {
        guard let d = coordinator else { return }
        subEnabled = true; subGain = 0; subPolarity = false
        try? await sonosManager.setEQ(device: d, eqType: "SubEnable", value: 1)
        try? await sonosManager.setEQ(device: d, eqType: "SubGain", value: 0)
        try? await sonosManager.setEQ(device: d, eqType: "SubPolarity", value: 0)
    }

    private func resetSurrounds() async {
        guard let d = coordinator else { return }
        surroundEnabled = true; surroundLevel = 0; musicSurroundLevel = 0; surroundMode = 1
        try? await sonosManager.setEQ(device: d, eqType: "SurroundEnable", value: 1)
        try? await sonosManager.setEQ(device: d, eqType: "SurroundLevel", value: 0)
        try? await sonosManager.setEQ(device: d, eqType: "MusicSurroundLevel", value: 0)
        try? await sonosManager.setEQ(device: d, eqType: "SurroundMode", value: 1)
    }
}
