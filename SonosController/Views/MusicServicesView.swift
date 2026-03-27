/// MusicServicesView.swift — Manage music service connections and browse authenticated content.
import SwiftUI
import SonosKit
import AppKit

struct MusicServicesSettingsSection: View {
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @State private var searchText = ""

    private var filteredServices: [SMAPIServiceDescriptor] {
        let all = smapiManager.availableServices
            .filter { smapiManager.tokenStore.authenticatedServices[$0.id] == nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if searchText.isEmpty { return all }
        let query = searchText.lowercased()
        return all.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        Toggle("Music Service Browsing (Beta)", isOn: Binding(
            get: { smapiManager.isEnabled },
            set: { smapiManager.isEnabled = $0 }
        ))

        if smapiManager.isEnabled {
            // Connected services
            if !smapiManager.authenticatedServiceList.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(smapiManager.authenticatedServiceList, id: \.id) { service in
                        HStack {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text(service.name)
                                .font(.caption)
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

            // Available services with search
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Available (\(filteredServices.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
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
                                Text(service.authType)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                if service.authType == "Anonymous" {
                                    Text("No login")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                } else if service.authType == "AppLink" || service.authType == "DeviceLink" {
                                    Button("Connect") {
                                        connectService(service)
                                    }
                                    .controlSize(.mini)
                                    .disabled(smapiManager.isAuthenticating)
                                } else {
                                    Text("Unsupported")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
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

            Text("Connect to browse and search music services. Credentials stored in macOS Keychain.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

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

// MARK: - Service Browse View (for authenticated SMAPI services)

struct ServiceBrowseView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let service: SMAPIServiceDescriptor
    let group: SonosGroup?

    @State private var items: [SMAPIMediaItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var breadcrumbs: [(String, String)] = [] // (title, id)
    @State private var searchText = ""

    private var currentID: String {
        breadcrumbs.last?.1 ?? "root"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Navigation
            HStack(spacing: 6) {
                if !breadcrumbs.isEmpty {
                    Button {
                        breadcrumbs.removeAll()
                        Task { await loadContent(id: "root") }
                    } label: {
                        Image(systemName: "house.fill").font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                }
                if breadcrumbs.count > 1 {
                    Button {
                        breadcrumbs.removeLast()
                        Task { await loadContent(id: currentID) }
                    } label: {
                        Image(systemName: "chevron.backward").font(.system(size: 14, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                }

                Text(breadcrumbs.last?.0 ?? service.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Spacer()

                // Search
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                    TextField("Search \(service.name)", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .onSubmit { performSearch() }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 160)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            Divider()

            // Content
            if isLoading {
                ProgressView(L10n.loading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.secondary)
                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if items.isEmpty {
                Text("No content").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items, id: \.id) { item in
                            Button {
                                handleTap(item)
                            } label: {
                                ServiceItemRow(item: item)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if item.canPlay, let group = group {
                                    Button("Play Now") {
                                        playItem(item, in: group)
                                    }
                                    Button("Add to Queue") {
                                        addToQueue(item, in: group)
                                    }
                                }
                                if item.canBrowse {
                                    Button("Browse") {
                                        navigateTo(item)
                                    }
                                }
                            }
                            Divider().padding(.leading, 64)
                        }
                    }
                }
            }
        }
        .onAppear {
            Task { await loadContent(id: "root") }
        }
    }

    // MARK: - Actions

    private func loadContent(id: String) async {
        guard let token = smapiManager.tokenStore.getToken(for: service.id) else {
            errorMessage = "Not signed in to \(service.name)"
            isLoading = false
            return
        }
        isLoading = true
        errorMessage = nil
        do {
            let (result, _) = try await smapiManager.client.getMetadata(
                serviceURI: service.secureUri, token: token, id: id
            )
            items = result
        } catch {
            errorMessage = (error as? SMAPIError).map(AppError.from)?.errorDescription ?? error.localizedDescription
        }
        isLoading = false
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        guard let token = smapiManager.tokenStore.getToken(for: service.id) else { return }
        Task {
            isLoading = true
            errorMessage = nil
            do {
                let (result, _) = try await smapiManager.client.search(
                    serviceURI: service.secureUri, token: token, term: query
                )
                items = result
                breadcrumbs.append(("Search: \(query)", "search:\(query)"))
            } catch {
                errorMessage = (error as? SMAPIError).map(AppError.from)?.errorDescription ?? error.localizedDescription
            }
            isLoading = false
        }
    }

    private func navigateTo(_ item: SMAPIMediaItem) {
        breadcrumbs.append((item.title, item.id))
        Task { await loadContent(id: item.id) }
    }

    private func handleTap(_ item: SMAPIMediaItem) {
        if item.canBrowse {
            navigateTo(item)
        } else if item.canPlay, let group = group {
            playItem(item, in: group)
        }
    }

    /// Constructs the correct Sonos URI based on service and item type
    private func buildSonosURI(for item: SMAPIMediaItem) -> String {
        let encodedID = item.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.id
        let sn = smapiManager.serialNumber(for: service.id)

        // Radio streams use x-sonosapi-stream with flags=8224 for most, flags=32 for basic
        let radioFlags = sn > 0 ? 8224 : 32
        if item.itemType == "stream" || item.itemType == "show" {
            return "x-sonosapi-stream:\(encodedID)?sid=\(service.id)&flags=\(radioFlags)&sn=\(sn)"
        }

        // TuneIn and radio services
        if service.name.lowercased().contains("tunein") || service.name.lowercased().contains("radio") {
            return "x-sonosapi-stream:\(encodedID)?sid=\(service.id)&flags=\(radioFlags)&sn=\(sn)"
        }

        // HLS streams (Apple Music style)
        if item.uri.contains("hls") || item.itemType == "track" && service.id == 204 {
            return "x-sonosapi-hls-static:\(encodedID)?sid=\(service.id)&flags=8232&sn=\(sn)"
        }

        // Default: x-sonos-http for most music services
        return "x-sonos-http:\(encodedID)?sid=\(service.id)&flags=8232&sn=\(sn)"
    }

    private func playItem(_ item: SMAPIMediaItem, in group: SonosGroup) {
        Task {
            do {
                let uri = buildSonosURI(for: item)
                sonosDebugLog("[SMAPI] Playing: \(item.title) uri=\(uri.prefix(80))")
                try await sonosManager.playURI(
                    group: group, uri: uri,
                    title: item.title, artist: item.artist,
                    stationName: item.itemType == "stream" ? item.title : "",
                    albumArtURI: item.albumArtURI.isEmpty ? nil : item.albumArtURI
                )
            } catch {
                sonosDebugLog("[SMAPI] Play failed: \(error)")
            }
        }
    }

    private func addToQueue(_ item: SMAPIMediaItem, in group: SonosGroup) {
        let uri = buildSonosURI(for: item)
        let browseItem = BrowseItem(
            id: item.id, title: item.title, artist: item.artist, album: item.album,
            albumArtURI: item.albumArtURI.isEmpty ? nil : item.albumArtURI,
            resourceURI: uri
        )
        Task {
            try? await sonosManager.addBrowseItemToQueue(browseItem, in: group)
        }
    }
}

// MARK: - Service Item Row

private struct ServiceItemRow: View {
    let item: SMAPIMediaItem

    var body: some View {
        HStack(spacing: 12) {
            if !item.albumArtURI.isEmpty {
                CachedAsyncImage(url: URL(string: item.albumArtURI))
                    .frame(width: 40, height: 40)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: item.canBrowse ? "folder.fill" : "music.note")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: 40, height: 40)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body)
                    .lineLimit(1)
                if !item.artist.isEmpty {
                    Text(item.artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if item.canBrowse {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
