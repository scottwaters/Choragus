/// SonosRadioSearchView.swift — Search Sonos Radio via anonymous SMAPI.
/// Browse categories require DeviceLink auth which is not supported — search only.
import SwiftUI
import SonosKit

struct SonosRadioSearchView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    let group: SonosGroup?

    @State private var searchText = ""
    @State private var items: [BrowseItem] = []
    @State private var isLoading = false
    @State private var hasSearched = false

    private var serviceDescriptor: SMAPIServiceDescriptor? {
        smapiManager.availableServices.first { $0.id == ServiceID.sonosRadio }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Search Sonos Radio...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                        .onSubmit { performSearch() }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color(nsColor: .quaternaryLabelColor).opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

                Button("Search") { performSearch() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if isLoading {
                ProgressView("Searching...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty && hasSearched {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No results found")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("Search for Sonos Radio stations")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    BrowseItemRow(item: item)
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(item) }
                        .contextMenu { contextMenu(for: item) }
                }
                .listStyle(.plain)
            }
        }
    }

    private func handleTap(_ item: BrowseItem) {
        guard let uri = item.resourceURI, !uri.isEmpty, !item.isContainer, let group else { return }
        Task {
            try? await sonosManager.playBrowseItem(item, in: group)
        }
    }

    @ViewBuilder
    private func contextMenu(for item: BrowseItem) -> some View {
        if let group, let uri = item.resourceURI, !uri.isEmpty, !item.isContainer {
            Button("Play Now") {
                Task { try? await sonosManager.playBrowseItem(item, in: group) }
            }
            Button("Play Next") {
                Task { try? await sonosManager.addBrowseItemToQueue(item, in: group, playNext: true) }
            }
            Button("Add to Queue") {
                Task { try? await sonosManager.addBrowseItemToQueue(item, in: group) }
            }
        }
    }

    private func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isLoading = true
        hasSearched = true
        Task {
            // Ensure services are loaded
            if smapiManager.availableServices.isEmpty || smapiManager.deviceID == nil {
                if let speaker = sonosManager.groups.first?.coordinator {
                    await smapiManager.loadServices(speakerIP: speaker.ip, musicServicesList: sonosManager.musicServicesList)
                }
            }
            guard let service = serviceDescriptor, let deviceID = smapiManager.deviceID else {
                isLoading = false
                return
            }
            let sn = smapiManager.serialNumber(for: ServiceID.sonosRadio)
            let householdID = smapiManager.householdID
            items = await ServiceSearchProvider.shared.searchSMAPIAnonymous(
                term: query, searchID: "station", serviceID: ServiceID.sonosRadio,
                serviceURI: service.secureUri, deviceID: deviceID, householdID: householdID, sn: sn)
            if items.isEmpty {
                items = await ServiceSearchProvider.shared.searchSMAPIAnonymous(
                    term: query, searchID: "track", serviceID: ServiceID.sonosRadio,
                    serviceURI: service.secureUri, deviceID: deviceID, householdID: householdID, sn: sn)
            }
            isLoading = false
        }
    }
}
