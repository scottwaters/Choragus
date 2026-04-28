/// MusicServicesView.swift — Manage music service connections and browse authenticated content.
import SwiftUI
import SonosKit
import AppKit

struct MusicServicesSettingsSection: View {
    @EnvironmentObject var smapiManager: SMAPIAuthManager
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var plexAuth: PlexAuthManager
    @AppStorage(UDKey.tuneInSearchEnabled) private var tuneInEnabled = false
    @AppStorage(UDKey.calmRadioEnabled) private var calmRadioEnabled = false
    @AppStorage(UDKey.appleMusicSearchEnabled) private var appleMusicEnabled = false
    @AppStorage(UDKey.sonosRadioEnabled) private var sonosRadioEnabled = false
    @State private var searchText = ""
    @State private var showHelp = false
    @State private var isLoadingDescriptors = false
    @State private var showPlexPinSheet = false
    @State private var plexPinStartError: String?
    @AppStorage("musicServices.unlinkedExpanded") private var unlinkedExpanded = false

    // Services confirmed working with AppLink auth. Plex (sid=212) was
    // verified by live `getAppLink` probe (2026-04-24); Audible
    // (sid=239) confirmed end-to-end on the realigned Choragus
    // keychain (2026-04-28).
    private static let testedAppLinkServices: Set<Int> = [
        ServiceID.spotify,
        ServiceID.plex,
        ServiceID.audible,
    ]

    /// Services where the connected status doesn't depend on the `sn=`
    /// favorites-discovery mechanism. Plex streams from the user's own
    /// server so no subscription serial number exists or is needed.
    private static let servicesNotNeedingSN: Set<Int> = [
        ServiceID.plex,
    ]

    /// Services that can never authenticate from a third-party app —
    /// Sonos's identity gate returns 403 to non-Sonos clients.
    private static let blockedServices: Set<Int> = [
        ServiceID.amazonMusic,
        ServiceID.youTubeMusic,
        ServiceID.soundCloud,
    ]

    /// Services that work via direct API rather than AppLink OAuth — toggled
    /// on/off rather than connected. Apple Music is search-only via iTunes;
    /// playback still requires Sonos-side connection + favourited song.
    private static let searchOnlyServices: Set<Int> = [
        ServiceID.tuneIn,
        ServiceID.tuneInNew,
        ServiceID.calmRadio,
        ServiceID.appleMusic,
        ServiceID.sonosRadio,
    ]

    /// Plex has two independent auth paths — direct PMS (PIN flow,
    /// `PlexAuthManager`) and Sonos cloud relay (SMAPI). They're shown
    /// as two separate rows so the user can connect either, both, or
    /// neither — and the sidebar surfaces a corresponding entry per
    /// connected path. For every other service this is `.none`.
    enum PlexFlavor { case none, local, cloud }

    struct CanonicalService {
        let key: String          // unique per row, e.g. "212.local"
        let serviceID: Int       // Sonos service id; same for both Plex flavors
        let name: String         // user-visible label
        let alternativeIDs: [Int]
        let plexFlavor: PlexFlavor
    }

    /// Pinned rows we always show regardless of household state.
    /// Plex – Local (PIN flow, no household needed) plus the search-only
    /// services that work via public APIs (Apple Music search, TuneIn,
    /// Calm Radio, Sonos Radio). Blocked services (Amazon, YouTube
    /// Music, SoundCloud) are NOT pinned — they only surface for
    /// users who actually have them (detected via account serial
    /// numbers from their Sonos Favorites).
    private static let pinnedServices: [CanonicalService] = [
        .init(key: "212.local", serviceID: ServiceID.plex,       name: "Plex – Local", alternativeIDs: [], plexFlavor: .local),
        .init(key: "204",       serviceID: ServiceID.appleMusic, name: "Apple Music",  alternativeIDs: [], plexFlavor: .none),
        .init(key: "254",       serviceID: ServiceID.tuneIn,     name: "TuneIn",       alternativeIDs: [ServiceID.tuneInNew], plexFlavor: .none),
        .init(key: "144",       serviceID: ServiceID.calmRadio,  name: "Calm Radio",   alternativeIDs: [], plexFlavor: .none),
        .init(key: "303",       serviceID: ServiceID.sonosRadio, name: "Sonos Radio",  alternativeIDs: [], plexFlavor: .none),
    ]

    /// Builds the actual list of rows to display.
    ///
    /// Layered build:
    ///   1. Pinned curated rows (Plex – Local, search-only services).
    ///   2. Plex – Cloud, if there's any signal it's set up.
    ///   3. Authenticated services (we hold a token).
    ///   4. Services with discovered account serial numbers (user has
    ///      a Favorite that references them — proof they linked it).
    ///   5. Everything else from Sonos's full service catalogue,
    ///      alphabetised. These render as either "Not connected"
    ///      (gray) or "Unavailable" (red, for provider-gated ones)
    ///      so the user sees the full Sonos universe with state, but
    ///      none of them masquerade as Available.
    private func buildServiceList() -> [CanonicalService] {
        var out = Self.pinnedServices
        let hasSMAPIPlexToken = smapiManager.tokenStore.authenticatedServices[ServiceID.plex] != nil
        let hasPlexSerial = smapiManager.serviceSerialNumbers[ServiceID.plex] != nil
        // Also surface the row when the Sonos household lists Plex as
        // available — without this, a user who's linked Plex in the
        // Sonos app but never authed it through Choragus (or who lost
        // the token to a keychain reset) has no entry point to start
        // the cloud-auth flow. The row falls through to `.notInHousehold`
        // gray naturally if Plex isn't in the catalogue.
        let plexInHousehold = smapiManager.availableServices.contains { $0.id == ServiceID.plex }
        if hasSMAPIPlexToken || hasPlexSerial || plexInHousehold {
            out.append(.init(key: "212.cloud", serviceID: ServiceID.plex,
                             name: "Plex – Cloud", alternativeIDs: [], plexFlavor: .cloud))
        }
        var coveredIDs: Set<Int> = []
        for svc in out {
            coveredIDs.insert(svc.serviceID)
            for alt in svc.alternativeIDs { coveredIDs.insert(alt) }
        }
        for sid in smapiManager.tokenStore.authenticatedServices.keys where !coveredIDs.contains(sid) {
            out.append(.init(key: "\(sid).auth", serviceID: sid, name: serviceName(for: sid),
                             alternativeIDs: [], plexFlavor: .none))
            coveredIDs.insert(sid)
        }
        let serialIDs = smapiManager.serviceSerialNumbers.keys
            .filter { !coveredIDs.contains($0) }
            .map { (id: $0, name: serviceName(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for entry in serialIDs {
            out.append(.init(key: "\(entry.id).sn", serviceID: entry.id, name: entry.name,
                             alternativeIDs: [], plexFlavor: .none))
            coveredIDs.insert(entry.id)
        }
        // Catalog tail — every other service Sonos knows about.
        // These render gray ("Not connected") or red ("Unavailable").
        let catalog = smapiManager.availableServices
            .filter { !coveredIDs.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        for desc in catalog {
            out.append(.init(key: "\(desc.id).cat", serviceID: desc.id, name: desc.name,
                             alternativeIDs: [], plexFlavor: .none))
            coveredIDs.insert(desc.id)
        }
        return out
    }

    /// Best-effort service name lookup. Prefers a descriptor (gives the
    /// real Sonos label like "Pocket Casts"), falls back to our
    /// hard-coded `knownNames`, then to a generic "Service N" if we've
    /// never heard of it.
    private func serviceName(for serviceID: Int) -> String {
        if let desc = smapiManager.availableServices.first(where: { $0.id == serviceID }) {
            return desc.name
        }
        return ServiceID.knownNames[serviceID] ?? "Service \(serviceID)"
    }

    /// Per-row UI state — drives both the indicator dot and the action UI.
    private enum ServiceRowState {
        /// User has authenticated via SMAPI. Sub-state: whether the `sn=`
        /// account identifier was discovered (favourited-song step done).
        case authenticated(needsFavorite: Bool)
        /// In-household, search-only (TuneIn / Calm Radio / Sonos Radio /
        /// Apple Music search). Toggle on/off.
        case searchOnlyAvailable
        /// In-household, OAuth-required, confirmed working (Spotify, Plex).
        case connectableTested
        /// In-household, OAuth-required, untested in the wild.
        case connectableUntested
        /// Sonos descriptors loaded and don't include this service.
        case notInHousehold
        /// Sonos-identity gate blocks this service for any third-party app.
        case blocked
    }

    /// Resolves the per-row state for a given service ID. The household
    /// check is strict: until Sonos descriptors come back we treat the
    /// service as not-in-household. The previous "forgiving" default
    /// flashed every service as connectable on cold-start, which let
    /// users tap Connect on services they don't have (TIDAL, Deezer…)
    /// and produced confusing errors. The list now stays gray until
    /// `loadDescriptorsIfNeeded` resolves.
    private func state(for service: CanonicalService) -> ServiceRowState {
        // Plex flavors have independent auth state — local checks
        // PlexAuthManager, cloud checks SMAPI tokens. Each row tells
        // the user about its own connection only.
        switch service.plexFlavor {
        case .local:
            if plexAuth.isAuthenticated { return .authenticated(needsFavorite: false) }
            // Direct PMS doesn't need a Sonos household entry — it's a
            // PIN-flow connection straight to plex.tv. Always connectable.
            return .connectableTested
        case .cloud:
            if smapiManager.tokenStore.authenticatedServices[ServiceID.plex] != nil {
                let needsFavorite = !Self.servicesNotNeedingSN.contains(ServiceID.plex)
                    && smapiManager.serviceSerialNumbers[ServiceID.plex] == nil
                return .authenticated(needsFavorite: needsFavorite)
            }
            // Cloud Plex needs the SMAPI relay — household + descriptor.
            let descriptorsLoaded = !smapiManager.availableServices.isEmpty
            let isInHousehold = descriptorsLoaded
                && smapiManager.availableServices.contains { $0.id == ServiceID.plex }
            if !isInHousehold { return .notInHousehold }
            return .connectableTested
        case .none:
            break
        }
        let serviceID = service.serviceID
        if smapiManager.tokenStore.authenticatedServices[serviceID] != nil {
            let needsFavorite = !Self.servicesNotNeedingSN.contains(serviceID)
                && smapiManager.serviceSerialNumbers[serviceID] == nil
            return .authenticated(needsFavorite: needsFavorite)
        }
        // Search-only services use public APIs (Apple Music, TuneIn, etc.)
        // — they don't need to be in the household to work, so always offer
        // the toggle regardless of descriptor state.
        if Self.searchOnlyServices.contains(serviceID) { return .searchOnlyAvailable }
        // Provider-gated services render red ("Unavailable") regardless
        // of household. The provider has decided third-party clients
        // can't authenticate to it, so showing the user a Connect
        // button would be misleading.
        if Self.blockedServices.contains(serviceID) { return .blocked }
        // Tested AppLink services (Spotify, Plex) — known to work,
        // confidence-blue.
        if Self.testedAppLinkServices.contains(serviceID) { return .connectableTested }
        // Everything else: we genuinely don't know. The previous code
        // returned .notInHousehold (gray) here based on a serial-number
        // check, but absence of an sn doesn't mean absence from the
        // household — it just means we haven't seen a Favorite for
        // that service yet (Audible audiobooks, Pocket Casts shows,
        // etc. often have URIs that don't match our `sid=…&sn=…`
        // extraction pattern). Treat everything unknown as
        // .connectableUntested so the user gets a "try it and report"
        // affordance instead of a misleading "not connected" gray.
        return .connectableUntested
    }

    /// Sort priority for state ordering: authenticated → available → others.
    private static func sortPriority(_ state: ServiceRowState) -> Int {
        switch state {
        case .authenticated:        return 0
        case .searchOnlyAvailable:  return 1
        case .connectableTested:    return 2
        case .connectableUntested:  return 3
        case .notInHousehold:       return 4
        case .blocked:              return 5
        }
    }

    var body: some View {
        Group {
            bodyContent
        }
        .onAppear { loadDescriptorsIfNeeded() }
        .sheet(isPresented: $showPlexPinSheet) {
            PlexPinAuthSheet(plexAuth: plexAuth, onClose: { showPlexPinSheet = false })
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        // ─── SETUP GUIDE (prominent, first thing users see) ───
        Button {
            showHelp = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "book.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.musicServicesSetupGuide)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(L10n.firstTimeHereSetupSteps)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.30), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showHelp) {
            MusicServicesHelpView()
        }

        // ─── LINKED SERVICES (always visible) ───
        // Authenticated services + search-only toggleable services.
        // No per-row hint text — the colored dot is the entire status
        // (green = connected, blue = toggle-on, orange = needs favorite).
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.connectedServicesHeader)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isLoadingDescriptors {
                    ProgressView().controlSize(.mini)
                    Text(L10n.checkingSonosHousehold)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            let rows = orderedServiceRows()
            let linked = rows.filter { isLinkedRow($0.state) }
            let unlinked = rows.filter { !isLinkedRow($0.state) }
            if linked.isEmpty {
                Text(L10n.noServicesConnectedYet)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(linked, id: \.service.key) { row in
                    serviceRow(service: row.service, state: row.state)
                }
            }

            // ─── AUTH STATUS (inline so it's near the rows it affects) ───
            if smapiManager.isAuthenticating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.waitingForService(smapiManager.authServiceName))
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.cancel) {
                        smapiManager.cancelAuth()
                    }
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            if let error = smapiManager.authError {
                Text(error)
                    .font(.body)
                    .foregroundStyle(.red)
                    .padding(.top, 4)
            }

            // ─── COLLAPSIBLE: UNLINKED SERVICES ───
            if !unlinked.isEmpty {
                Divider().padding(.vertical, 4)
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        unlinkedExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.callout)
                            .rotationEffect(unlinkedExpanded ? .degrees(90) : .zero)
                        Text(L10n.otherServicesAvailable(unlinked.count))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if unlinkedExpanded {
                    legendStrip
                        .padding(.leading, 18)
                        .padding(.top, 4)
                    ForEach(unlinked, id: \.service.key) { row in
                        serviceRow(service: row.service, state: row.state)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    /// Legend shown at the top of the unlinked services section.
    /// One descriptive line per state — the colored dots in the rows
    /// below match. Per-row hints stay off so the rows themselves
    /// aren't noisy; the legend explains the meaning once.
    private var legendStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendLine(color: .blue, text: L10n.legendAvailable)
            legendLine(color: .yellow, text: L10n.legendUntested)
            legendLine(color: .red, text: L10n.legendUnavailable)
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.right.square")
                    .font(.callout)
                Button(L10n.openGitHubIssues) {
                    if let url = URL(string: "https://github.com/scottwaters/Choragus/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private func legendLine(color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
                .padding(.top, 4)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// "Linked" = either authenticated or a search-only toggleable
    /// service. Everything else (connectable, not-in-household,
    /// blocked) goes in the collapsed section.
    private func isLinkedRow(_ state: ServiceRowState) -> Bool {
        switch state {
        case .authenticated, .searchOnlyAvailable: return true
        default: return false
        }
    }

    /// Builds the ordered list of rows. State is computed once per render so
    /// the sort + the row both see the same answer.
    private func orderedServiceRows() -> [(service: CanonicalService, state: ServiceRowState)] {
        buildServiceList()
            .map { (service: $0, state: state(for: $0)) }
            .sorted { lhs, rhs in
                let lp = Self.sortPriority(lhs.state)
                let rp = Self.sortPriority(rhs.state)
                if lp != rp { return lp < rp }
                return lhs.service.name.localizedCaseInsensitiveCompare(rhs.service.name) == .orderedAscending
            }
    }

    /// Single-row renderer. Keeps row layout consistent across all states so
    /// the list reads as a uniform table even though actions vary per row.
    @ViewBuilder
    private func serviceRow(service: CanonicalService, state: ServiceRowState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle()
                    .fill(rowDotColor(state))
                    .frame(width: 8, height: 8)
                Text(service.name)
                    .font(.body)
                    .foregroundStyle(rowTextStyle(state))
                Spacer()
                rowAction(service: service, state: state)
            }
            // Inline status / action hint per state.
            if let hint = rowHint(service: service, state: state) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: rowHintIcon(state))
                        .font(.callout)
                        .foregroundStyle(rowDotColor(state))
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 18)
            }
        }
        .padding(.vertical, 2)
    }

    private func rowDotColor(_ state: ServiceRowState) -> Color {
        switch state {
        case .authenticated(let needsFavorite):  return needsFavorite ? .orange : .green
        case .searchOnlyAvailable:                return .blue
        case .connectableTested:                  return .blue
        case .connectableUntested:                return .yellow
        case .notInHousehold:                     return .gray
        case .blocked:                            return .red
        }
    }

    private func rowTextStyle(_ state: ServiceRowState) -> HierarchicalShapeStyle {
        switch state {
        case .notInHousehold, .blocked: return .secondary
        default:                         return .primary
        }
    }

    @ViewBuilder
    private func rowAction(service: CanonicalService, state: ServiceRowState) -> some View {
        switch state {
        case .authenticated:
            Button(L10n.signOut) { signOut(service: service) }
                .controlSize(.small)
                .foregroundStyle(.red)
        case .searchOnlyAvailable:
            Toggle("", isOn: searchOnlyBinding(for: service.serviceID))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        case .connectableTested, .connectableUntested:
            // Always render Connect — descriptors load lazily so we can't
            // gate the button on `availableServices` being populated.
            // `connectService(...)` resolves the descriptor at tap time,
            // triggering a load if needed.
            Button(L10n.connect) { connectService(service: service) }
                .controlSize(.small)
                .disabled(smapiManager.isAuthenticating)
        case .notInHousehold, .blocked:
            EmptyView()
        }
    }

    /// Service-aware sign-out. Plex's two flavors live on different
    /// stores — Local on PlexAuthManager (PIN flow), Cloud on
    /// SMAPITokenStore. Every other service is SMAPI.
    private func signOut(service: CanonicalService) {
        switch service.plexFlavor {
        case .local: plexAuth.signOut()
        case .cloud: smapiManager.signOut(serviceID: ServiceID.plex)
        case .none:  smapiManager.signOut(serviceID: service.serviceID)
        }
    }

    private func searchOnlyBinding(for serviceID: Int) -> Binding<Bool> {
        switch serviceID {
        case ServiceID.tuneIn, ServiceID.tuneInNew: return $tuneInEnabled
        case ServiceID.calmRadio:                    return $calmRadioEnabled
        case ServiceID.appleMusic:                   return $appleMusicEnabled
        case ServiceID.sonosRadio:                   return $sonosRadioEnabled
        default:                                      return .constant(false)
        }
    }

    private func rowHint(service: CanonicalService, state: ServiceRowState) -> String? {
        // Legend at the top of the collapsed section explains every
        // state — per-row hints just duplicate that. Sole exception:
        // needs-favorite, where the user has to take an action OUTSIDE
        // the app (open Sonos's app and favourite a track) to flip the
        // dot green; the legend can't carry that per-service step.
        switch state {
        case .authenticated(let needsFavorite) where needsFavorite:
            return L10n.playAnySongAndFavoriteFormat(service.name)
        default:
            return nil
        }
    }

    private func rowHintIcon(_ state: ServiceRowState) -> String {
        switch state {
        case .authenticated(let needsFavorite):
            return needsFavorite ? "arrow.turn.down.right" : "checkmark.circle.fill"
        case .notInHousehold: return "info.circle"
        case .blocked:        return "xmark.octagon.fill"
        default:              return "info.circle"
        }
    }

    private func legendRow(color: Color, label: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    /// Loads SMAPI service descriptors if not already populated. Settings
    /// can be opened before Browse — without this, the rows for OAuth
    /// services have nothing to act against and Connect would 404 at the
    /// Sonos side.
    private func loadDescriptorsIfNeeded() {
        guard smapiManager.isEnabled,
              smapiManager.availableServices.isEmpty,
              !isLoadingDescriptors,
              let speaker = sonosManager.groups.first?.coordinator else { return }
        isLoadingDescriptors = true
        Task {
            await smapiManager.loadServices(
                speakerIP: speaker.ip,
                musicServicesList: sonosManager.musicServicesList
            )
            isLoadingDescriptors = false
        }
    }

    /// Resolves the descriptor for the given service and starts auth.
    /// Plex – Local takes the PIN flow; everything else (Plex – Cloud
    /// included) uses the SMAPI AppLink path.
    private func connectService(service: CanonicalService) {
        if service.plexFlavor == .local {
            startPlexPinFlow()
            return
        }
        let serviceID = service.serviceID
        if let descriptor = smapiManager.availableServices.first(where: { $0.id == serviceID }) {
            startAuth(descriptor: descriptor)
            return
        }
        guard let speaker = sonosManager.groups.first?.coordinator else {
            smapiManager.authError = "No Sonos speaker found on the network."
            return
        }
        isLoadingDescriptors = true
        Task {
            await smapiManager.loadServices(
                speakerIP: speaker.ip,
                musicServicesList: sonosManager.musicServicesList
            )
            isLoadingDescriptors = false
            if let descriptor = smapiManager.availableServices.first(where: { $0.id == serviceID }) {
                startAuth(descriptor: descriptor)
            } else {
                smapiManager.authError =
                    "This service isn't currently registered in your Sonos household. Add it in the official Sonos app first."
            }
        }
    }

    private func startAuth(descriptor: SMAPIServiceDescriptor) {
        Task {
            if let url = await smapiManager.startAuth(service: descriptor),
               let nsURL = URL(string: url) {
                NSWorkspace.shared.open(nsURL)
            }
        }
    }

    /// Kicks off the Plex PIN flow. The sheet shown by
    /// `PlexPinAuthSheet` polls for completion and dismisses itself
    /// once the user claims the code at plex.tv/link.
    private func startPlexPinFlow() {
        plexPinStartError = nil
        showPlexPinSheet = true
        Task {
            do {
                _ = try await plexAuth.startPin()
            } catch {
                plexPinStartError = error.localizedDescription
                showPlexPinSheet = false
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
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
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
                            .font(.body.weight(.semibold))

                        HStack(spacing: 6) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text(L10n.statusActiveLine)
                                .font(.callout)
                        }
                        HStack(spacing: 6) {
                            Circle().fill(.orange).frame(width: 8, height: 8)
                            Text(L10n.statusNeedsFavoriteLine)
                                .font(.callout)
                        }
                        HStack(spacing: 6) {
                            Circle().fill(.gray).frame(width: 8, height: 8)
                            Text(L10n.statusNotConnectedLine)
                                .font(.callout)
                        }
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.whyStep3Header)
                            .font(.body.weight(.semibold))
                        Text(L10n.whyStep3Body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.blockedServicesHeader)
                            .font(.body.weight(.semibold))
                        Text(L10n.blockedServicesBody)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apple Music")
                            .font(.body.weight(.semibold))
                        Text(L10n.appleMusicNoteBody)
                            .font(.callout)
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
                    .font(.body.weight(.semibold))
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Plex PIN auth sheet

/// Walks the user through the Plex OAuth-style PIN flow:
///   1. We ask plex.tv for a strong PIN — a long random token, NOT a
///      typeable 4-character code. (Strong PINs are required for the
///      OAuth-style flow; weak ones are deprecated.)
///   2. User clicks "Sign in with Plex" — we open `app.plex.tv/auth`
///      with the token embedded in the URL fragment. They sign in /
///      authorize inside Plex's own web UI.
///   3. We poll `/api/v2/pins/<id>` every 2s. Once Plex flips
///      `authToken` from null to a string, the manager stores it.
///   4. On success the manager publishes `isAuthenticated = true`,
///      which triggers `onChange` here to dismiss the sheet.
///
/// The polling task lives on `PlexAuthManager`, not the view — closing
/// the sheet without claiming the PIN cancels the task there.
struct PlexPinAuthSheet: View {
    @ObservedObject var plexAuth: PlexAuthManager
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.connectToPlex)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    plexAuth.cancelPin()
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            Text("Choragus connects to your Plex server directly — no Sonos relay. You'll only need to do this once.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            if plexAuth.activePin != nil {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Click below to open Plex in your browser. Sign in if needed, then tap Allow. The code is embedded in the link — there's nothing to type.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        if let url = plexAuth.authorizeURL() {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        Label("Sign in with Plex", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)

                    HStack(spacing: 8) {
                        if plexAuth.isPolling {
                            ProgressView().controlSize(.small)
                            Text("Waiting for you to authorize on plex.tv…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 4)
                }
            } else if plexAuth.isPolling {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Asking plex.tv for a sign-in code…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }

            if let err = plexAuth.pinPollError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(width: 460, height: 360)
        .onChange(of: plexAuth.isAuthenticated) { _, isAuth in
            // Dismiss as soon as the manager flips to authenticated —
            // user gets the satisfaction of a fast close instead of
            // having to click "Done".
            if isAuth { onClose() }
        }
    }
}
