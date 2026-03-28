/// MusicServicesView.swift — Manage music service connections and browse authenticated content.
import SwiftUI
import SonosKit
import AppKit

struct MusicServicesSettingsSection: View {
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @State private var searchText = ""
    @State private var showHelp = false

    /// Services that block third-party AppLink auth (require native app OAuth)
    private static let blockedServices: Set<Int> = [
        204, // Apple Music — requires native Apple Sign-In, returns error 999
    ]

    private var filteredServices: [SMAPIServiceDescriptor] {
        let connectable = smapiManager.availableServices
            .filter { ($0.authType == "AppLink" || $0.authType == "DeviceLink") &&
                      smapiManager.tokenStore.authenticatedServices[$0.id] == nil &&
                      !Self.blockedServices.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if searchText.isEmpty { return connectable }
        let query = searchText.lowercased()
        return connectable.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        HStack {
            Toggle("Music Service Browsing (Beta)", isOn: Binding(
                get: { smapiManager.isEnabled },
                set: { smapiManager.isEnabled = $0 }
            ))
            Spacer()
            Button { showHelp = true } label: {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .tooltip("Setup Guide")
            .sheet(isPresented: $showHelp) {
                MusicServicesHelpView()
            }
        }

        if smapiManager.isEnabled {
            // Service status overview
            serviceStatusList

            Divider().padding(.vertical, 4)

            // Connected services
            if !smapiManager.authenticatedServiceList.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(smapiManager.authenticatedServiceList, id: \.id) { service in
                        HStack {
                            Circle()
                                .fill(smapiManager.serviceSerialNumbers[service.id] != nil ? .green : .orange)
                                .frame(width: 6, height: 6)
                            Text(service.name)
                                .font(.caption)
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
            }

            Divider().padding(.vertical, 4)

            // Available services with search
            VStack(alignment: .leading, spacing: 6) {
                Text("Available (\(filteredServices.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(filteredServices, id: \.id) { service in
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
                .frame(maxHeight: 200)
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
        }
    }

    // MARK: - Service Status

    private var serviceStatusList: some View {
        let allServices = smapiManager.availableServices.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let connected = Set(smapiManager.authenticatedServiceList.map(\.id))
        let withSN = smapiManager.serviceSerialNumbers

        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(allServices.filter { connected.contains($0.id) || withSN[$0.id] != nil }, id: \.id) { svc in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(connected.contains(svc.id) && withSN[svc.id] != nil ? .green :
                                  connected.contains(svc.id) ? .orange : .gray)
                            .frame(width: 6, height: 6)
                        Text(svc.name)
                            .font(.system(size: 11))
                        Spacer()
                        if connected.contains(svc.id) && withSN[svc.id] != nil {
                            Text("Active")
                                .font(.system(size: 9))
                                .foregroundStyle(.green)
                        } else if connected.contains(svc.id) {
                            Text("Connected — add a favorite")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        } else if withSN[svc.id] != nil {
                            Button("Connect") {
                                connectService(svc)
                            }
                            .controlSize(.mini)
                            .disabled(smapiManager.isAuthenticating)
                        }
                    }
                }
            }
        } label: {
            Text("Service Status")
                .font(.caption)
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
                    setupStep(number: 1, title: "Connect a Service", icon: "link",
                              text: "Find your service in the Available list and click Connect. A browser window will open for you to sign in and authorize access.")

                    setupStep(number: 2, title: "Complete Authorization", icon: "checkmark.shield",
                              text: "Sign in with your account in the browser. Once authorized, the service will appear in the Connected list. This may take a few seconds to detect.")

                    setupStep(number: 3, title: "Add One Favorite", icon: "star",
                              text: "Using the official Sonos app on your phone, play a station or track from this service and add it to your Sonos Favorites. This is required once per service to link your account for full playback.")

                    setupStep(number: 4, title: "Browse and Play", icon: "play.circle",
                              text: "The service will appear in the Browse sidebar under Music Services. You can browse categories, search, and play content directly.")

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
                        Text("Sonos uses an internal account identifier to authenticate streaming playback. This identifier is only created when content from a service is first used through the Sonos system. Adding one favorite through the official Sonos app creates this link. After that, all browsing and playback works from SonosController.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Unsupported Services")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Apple Music requires native Apple Sign-In which isn't available to third-party apps. Use Apple Music through Sonos Favorites instead — any favorites you add in the Sonos app will appear in the Favorites section.")
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
