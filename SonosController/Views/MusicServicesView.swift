/// MusicServicesView.swift — Manage music service connections and browse authenticated content.
import SwiftUI
import SonosKit
import AppKit

struct MusicServicesSettingsSection: View {
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @AppStorage(UDKey.tuneInSearchEnabled) private var tuneInEnabled = false
    @AppStorage(UDKey.calmRadioEnabled) private var calmRadioEnabled = false
    @AppStorage(UDKey.appleMusicSearchEnabled) private var appleMusicEnabled = false
    @AppStorage(UDKey.sonosRadioEnabled) private var sonosRadioEnabled = false
    @State private var searchText = ""
    @State private var showHelp = false

    // Services confirmed working with AppLink auth. Plex (sid=212) was
    // verified by live `getAppLink` probe (2026-04-24) — returns a
    // usable Plex OAuth regUrl, unlike Apple Music / YouTube Music /
    // SoundCloud which all 403 at the Sonos-identity gate.
    private static let testedAppLinkServices: Set<Int> = [
        ServiceID.spotify,
        ServiceID.plex,
    ]

    /// Services where the connected status doesn't depend on the `sn=`
    /// favorites-discovery mechanism. Plex streams from the user's own
    /// server so no subscription serial number exists or is needed.
    private static let servicesNotNeedingSN: Set<Int> = [
        ServiceID.plex,
    ]

    // Services that cannot use AppLink (require native OAuth or are broken)
    private static let blockedServices: Set<Int> = [
        ServiceID.appleMusic,   // Handled separately via iTunes API
        ServiceID.amazonMusic,  // Returns empty auth URL
        ServiceID.youTubeMusic, // Returns empty auth URL
        ServiceID.soundCloud,   // getAppLink returns Client.NOT_AUTHORIZED (403) to non-Sonos clients
        ServiceID.sonosRadio,   // Search works anonymously, browse requires DeviceLink (not supported)
    ]

    // Services already handled in the "No Connection Required" section
    private static let handledElsewhere: Set<Int> = [
        ServiceID.appleMusic,
        ServiceID.tuneIn,
        ServiceID.tuneInNew,
        ServiceID.calmRadio,
        ServiceID.sonosRadio,
    ]

    private var filteredServices: [SMAPIServiceDescriptor] {
        let connectable = smapiManager.availableServices
            .filter { ($0.authType == "AppLink" || $0.authType == "DeviceLink") &&
                      smapiManager.tokenStore.authenticatedServices[$0.id] == nil &&
                      !Self.blockedServices.contains($0.id) &&
                      !Self.handledElsewhere.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if searchText.isEmpty { return connectable }
        let query = searchText.lowercased()
        return connectable.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        // ─── NO CONNECTION REQUIRED ───
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.searchServicesHeader)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("TuneIn", isOn: $tuneInEnabled)
                .font(.system(size: 12))

            Toggle("Calm Radio", isOn: $calmRadioEnabled)
                .font(.system(size: 12))

            Toggle("Apple Music", isOn: $appleMusicEnabled)
                .font(.system(size: 12))

            Toggle("Sonos Radio", isOn: $sonosRadioEnabled)
                .font(.system(size: 12))

            Text(L10n.searchServicesIntroBody)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }

        Divider().padding(.vertical, 4)

        // ─── CONNECTION REQUIRED (TESTED) ───
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.connectedServicesHeader)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showHelp) {
                    MusicServicesHelpView()
                }
            }

            // Show connected services
            if !smapiManager.authenticatedServiceList.isEmpty {
                ForEach(smapiManager.authenticatedServiceList, id: \.id) { service in
                    HStack {
                        // Plex streams from the user's own server and
                        // doesn't use Sonos's sn= / favorites-discovery
                        // pattern. Treat it as Active whenever the token
                        // is present.
                        let isActive = Self.servicesNotNeedingSN.contains(service.id)
                            || smapiManager.serviceSerialNumbers[service.id] != nil
                        Circle()
                            .fill(isActive ? .green : .orange)
                            .frame(width: 6, height: 6)
                        Text(service.name)
                            .font(.system(size: 12))
                        if isActive {
                            Text(L10n.active)
                                .font(.system(size: 9))
                                .foregroundStyle(.green)
                        } else {
                            Text(L10n.needsFavorite)
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button(L10n.signOut) {
                            smapiManager.signOut(serviceID: service.id)
                        }
                        .controlSize(.mini)
                        .foregroundStyle(.red)
                    }
                }
            }

            // Show tested but unconnected services with Connect button
            let testedAvailable = smapiManager.availableServices
                .filter { Self.testedAppLinkServices.contains($0.id) &&
                          smapiManager.tokenStore.authenticatedServices[$0.id] == nil }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            if !testedAvailable.isEmpty {
                ForEach(testedAvailable, id: \.id) { service in
                    HStack {
                        Circle()
                            .fill(.gray)
                            .frame(width: 6, height: 6)
                        Text(service.name)
                            .font(.system(size: 12))
                        Spacer()
                        Button(L10n.connect) {
                            connectService(service)
                        }
                        .controlSize(.mini)
                        .disabled(smapiManager.isAuthenticating)
                    }
                }
            }

            Text(L10n.testedConnectedBody)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }

        // Auth status
        if smapiManager.isAuthenticating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L10n.waitingForService(smapiManager.authServiceName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.cancel) {
                    smapiManager.cancelAuth()
                }
                .controlSize(.mini)
            }
        }

        if let error = smapiManager.authError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }

        Divider().padding(.vertical, 4)

        // ─── OTHER SERVICES (UNTESTED) ───
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                    TextField(L10n.searchServicesPlaceholder, text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                let untested = filteredServices.filter { !Self.testedAppLinkServices.contains($0.id) }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(untested, id: \.id) { service in
                            HStack {
                                Text(service.name)
                                    .font(.caption)
                                Spacer()
                                Button(L10n.connect) {
                                    connectService(service)
                                }
                                .controlSize(.mini)
                                .disabled(smapiManager.isAuthenticating)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)

                Text(L10n.otherServicesBody)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } label: {
            Text(L10n.otherServicesAvailable(filteredServices.filter { !Self.testedAppLinkServices.contains($0.id) }.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider().padding(.vertical, 4)

        // ─── STATUS INFO ───
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.serviceAvailability)
                .font(.system(size: 11, weight: .semibold))

            Group {
                statusRow(color: .green, text: "TuneIn, Calm Radio — no connection needed, full browse and playback")
                statusRow(color: .green, text: "Apple Music — search via iTunes API, playback works if connected in Sonos app with one favorited song")
                statusRow(color: .green, text: "Spotify, Plex — tested and working with AppLink auth")
                statusRow(color: .green, text: "Sonos Radio — search only (browsing categories requires unsupported DeviceLink auth)")
                statusRow(color: .orange, text: "Amazon Music, YouTube Music, SoundCloud — blocked by Sonos-identity gate")
                statusRow(color: .gray, text: "Other services — untested, may work via AppLink")
            }
        }
    }

    private func statusRow(color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6).padding(.top, 4)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func connectService(_ service: SMAPIServiceDescriptor) {
        Task {
            if let url = await smapiManager.startAuth(service: service) {
                if let nsURL = URL(string: url) {
                    NSWorkspace.shared.open(nsURL)
                }
            }
        }
    }
}

// MARK: - Setup Guide

struct MusicServicesHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L10n.musicServicesSetupGuide)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    setupStep(number: 1, title: L10n.setupStep1Title, icon: "checkmark.circle",
                              text: L10n.setupStep1Body)

                    setupStep(number: 2, title: L10n.setupStep2Title, icon: "checkmark.shield",
                              text: L10n.setupStep2Body)

                    setupStep(number: 3, title: L10n.setupStep3Title, icon: "star",
                              text: L10n.setupStep3Body)

                    setupStep(number: 4, title: L10n.setupStep4Title, icon: "play.circle",
                              text: L10n.setupStep4Body)

                    VStack(alignment: .leading, spacing: 8) {
                        Label(L10n.serviceStatusLabel, systemImage: "circle.grid.2x2")
                            .font(.system(size: 12, weight: .semibold))

                        HStack(spacing: 6) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text(L10n.statusActiveLine)
                                .font(.caption)
                        }
                        HStack(spacing: 6) {
                            Circle().fill(.orange).frame(width: 8, height: 8)
                            Text(L10n.statusNeedsFavoriteLine)
                                .font(.caption)
                        }
                        HStack(spacing: 6) {
                            Circle().fill(.gray).frame(width: 8, height: 8)
                            Text(L10n.statusNotConnectedLine)
                                .font(.caption)
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.whyStep3Header)
                            .font(.system(size: 11, weight: .semibold))
                        Text(L10n.whyStep3Body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.blockedServicesHeader)
                            .font(.system(size: 11, weight: .semibold))
                        Text(L10n.blockedServicesBody)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Music")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L10n.appleMusicNoteBody)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 520)
    }

    private func setupStep(number: Int, title: String, icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(.blue.opacity(0.15))
                    .frame(width: 28, height: 28)
                Text("\(number)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
            }
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
