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

    // Services confirmed working with AppLink auth
    private static let testedAppLinkServices: Set<Int> = [
        ServiceID.spotify,
    ]

    // Services that cannot use AppLink (require native OAuth or are broken)
    private static let blockedServices: Set<Int> = [
        ServiceID.appleMusic,   // Handled separately via iTunes API
        ServiceID.amazonMusic,  // Returns empty auth URL
        ServiceID.youTubeMusic, // Returns empty auth URL
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
            Text("Search Services (No Connection Required)")
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

            Text("These services use public APIs and do not require sign-in here.\n\nTuneIn and Calm Radio support direct browsing and playback with no setup.\n\nApple Music uses the public iTunes API — no connection needed to search. For playback, Apple Music must be connected in the official Sonos app and you need one favorited song from Apple Music in your Sonos Favorites. This allows the app to discover your account credentials. Once that one favorited song exists, all search results become directly playable.\n\nSonos Radio supports search only — browsing categories requires DeviceLink authentication which is not currently supported.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }

        Divider().padding(.vertical, 4)

        // ─── CONNECTION REQUIRED (TESTED) ───
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Connected Services (Tested)")
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
                        Circle()
                            .fill(smapiManager.serviceSerialNumbers[service.id] != nil ? .green : .orange)
                            .frame(width: 6, height: 6)
                        Text(service.name)
                            .font(.system(size: 12))
                        if smapiManager.serviceSerialNumbers[service.id] != nil {
                            Text("Active")
                                .font(.system(size: 9))
                                .foregroundStyle(.green)
                        } else {
                            Text("Needs Favorite")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Sign Out") {
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
                        Button("Connect") {
                            connectService(service)
                        }
                        .controlSize(.mini)
                        .disabled(smapiManager.isAuthenticating)
                    }
                }
            }

            Text("Spotify has been tested and confirmed working. Connect your account, then add one favorited song through the Sonos app to enable full browsing and playback.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }

        // Auth status
        if smapiManager.isAuthenticating {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for \(smapiManager.authServiceName)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
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
                    TextField("Search services...", text: $searchText)
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
                                Button("Connect") {
                                    connectService(service)
                                }
                                .controlSize(.mini)
                                .disabled(smapiManager.isAuthenticating)
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)

                Text("These services have not been tested. They may work with AppLink authentication but results are not guaranteed. Amazon Music and YouTube Music require their own OAuth and cannot be connected here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } label: {
            Text("Other Services (\(filteredServices.filter { !Self.testedAppLinkServices.contains($0.id) }.count) available)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Divider().padding(.vertical, 4)

        // ─── STATUS INFO ───
        VStack(alignment: .leading, spacing: 4) {
            Text("Service Availability")
                .font(.system(size: 11, weight: .semibold))

            Group {
                statusRow(color: .green, text: "TuneIn, Calm Radio — no connection needed, full browse and playback")
                statusRow(color: .green, text: "Apple Music — search via iTunes API, playback works if connected in Sonos app with one favorited song")
                statusRow(color: .green, text: "Spotify — tested and working with AppLink auth")
                statusRow(color: .green, text: "Sonos Radio — search only (browsing categories requires unsupported DeviceLink auth)")
                statusRow(color: .orange, text: "Amazon Music, YouTube Music — blocked (require native OAuth)")
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
                Text("Music Services Setup Guide")
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
                    setupStep(number: 1, title: "Enable or Connect", icon: "checkmark.circle",
                              text: "Services that don't need a connection (TuneIn, Calm Radio, Apple Music Search) can be enabled with a checkbox. For Spotify, click Connect to sign in via your browser.")

                    setupStep(number: 2, title: "Complete Authorization", icon: "checkmark.shield",
                              text: "For connected services, sign in with your account in the browser. Once authorized, the service will appear in the Connected list.")

                    setupStep(number: 3, title: "Add One Favorited Song", icon: "star",
                              text: "For connected services only: using the official Sonos app on your phone, play a song from this service and add it to your Sonos Favorites. This links your account for playback.")

                    setupStep(number: 4, title: "Browse and Play", icon: "play.circle",
                              text: "Enabled services appear in the Browse panel under Service Search. You can browse, search, and play content directly.")

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Service Status", systemImage: "circle.grid.2x2")
                            .font(.system(size: 12, weight: .semibold))

                        HStack(spacing: 6) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("Active — Connected and ready to play")
                                .font(.caption)
                        }
                        HStack(spacing: 6) {
                            Circle().fill(.orange).frame(width: 8, height: 8)
                            Text("Needs Favorite — Connected but needs step 3")
                                .font(.caption)
                        }
                        HStack(spacing: 6) {
                            Circle().fill(.gray).frame(width: 8, height: 8)
                            Text("Not connected — use Connect button")
                                .font(.caption)
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Why is step 3 needed?")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Sonos uses an internal account identifier to authenticate streaming playback. This identifier is only created when content from a service is first used through the Sonos system. Adding one favorite through the official Sonos app creates this link.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blocked Services")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Amazon Music and YouTube Music require their own native OAuth systems which are not available to third-party apps.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Music")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Apple Music search works without connection using the public iTunes API. For playback, Apple Music must be connected in the official Sonos app, and you need one favorited song from Apple Music in your Sonos Favorites. This allows the app to discover your account credentials. Once that exists, all search results are directly playable.")
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
