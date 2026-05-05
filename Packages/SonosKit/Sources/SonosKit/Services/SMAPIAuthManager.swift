/// SMAPIAuthManager.swift — Manages SMAPI authentication flow and service discovery.
import Foundation
import Combine

@MainActor
public final class SMAPIAuthManager: ObservableObject {
    public let client = SMAPIClient.shared
    public let tokenStore = SMAPITokenStore()

    @Published public var availableServices: [SMAPIServiceDescriptor] = []
    @Published public var isAuthenticating = false
    @Published public var authServiceName = ""
    @Published public var authError: String?

    /// Forward tokenStore changes so views observing this manager re-render
    /// when authentication state changes. Without this, tokens save fine
    /// but `MusicServicesView` / `BrowseView` (which both depend on the
    /// computed `authenticatedServiceList`) don't refresh because tokenStore
    /// is a separate ObservableObject whose objectWillChange doesn't
    /// propagate up automatically.
    private var tokenStoreSubscription: AnyCancellable?

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: UDKey.smapiEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.smapiEnabled); objectWillChange.send() }
    }

    public private(set) var deviceID: String?
    public private(set) var householdID = ""

    /// Maps service ID to account serial number (sn) extracted from favorites/history
    @Published public var serviceSerialNumbers: [Int: Int] = [:]

    public init() {
        // SMAPI is always-on for this app — there's no user-facing toggle
        // and every reader (BrowseView, MusicServicesView, app onAppear)
        // gates work on `isEnabled`. Without a registered default the flag
        // reads `false` on a fresh sandbox container (e.g. after the
        // bundle-ID rename to com.choragus.app), which silently breaks
        // service discovery and the Connect flow.
        UserDefaults.standard.register(defaults: [UDKey.smapiEnabled: true])

        // Forward nested ObservableObject changes — see comment on
        // tokenStoreSubscription above. Also push the latest tokens
        // into ServiceSearchProvider so its DIDL builder can stamp the
        // authenticated cdudn form for AppLink-authenticated services.
        tokenStoreSubscription = tokenStore.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
            // objectWillChange fires before the dict mutation lands;
            // hop to the next runloop tick so we read the new state.
            DispatchQueue.main.async { [weak self] in self?.pushAuthTokenSnapshot() }
        }
        // Initial seed in case tokens were already loaded from disk
        // before this subscription was wired.
        DispatchQueue.main.async { [weak self] in self?.pushAuthTokenSnapshot() }

        // Listen for token refresh notifications
        NotificationCenter.default.addObserver(forName: .smapiTokenRefreshed, object: nil, queue: .main) { [weak self] notification in
            guard let info = notification.userInfo,
                  let serviceID = info["serviceID"] as? Int,
                  let token = info["authToken"] as? String,
                  let key = info["privateKey"] as? String else { return }
            Task { @MainActor in
                self?.tokenStore.updateToken(serviceID: serviceID, authToken: token, privateKey: key)
            }
        }
    }

    /// Snapshots authenticated tokens and pushes them to
    /// `ServiceSearchProvider.shared` so DIDL builders stamp the
    /// authenticated cdudn form for AppLink-authenticated services.
    private func pushAuthTokenSnapshot() {
        var snapshot: [Int: String] = [:]
        for (sid, _) in tokenStore.authenticatedServices {
            if let stored = tokenStore.getToken(for: sid)?.authToken, !stored.isEmpty {
                snapshot[sid] = stored
            }
        }
        ServiceSearchProvider.shared.updateAuthTokens(snapshot)
    }

    // MARK: - Service Discovery

    /// Loads available services and device identity from a speaker.
    ///
    /// Service-descriptor fetching is delegated to `MusicServiceCatalog`,
    /// which owns the SOAP call and the per-household sid → name table.
    /// We then derive `availableServices` from the catalog's published
    /// descriptors so existing UI code (BrowseView, MusicServicesView)
    /// keeps reading from this manager without needing to migrate to the
    /// catalog directly. The ambassador speaker IP is bound on the
    /// catalog so its periodic / miss-triggered refresh paths know where
    /// to call.
    public func loadServices(speakerIP: String, musicServicesList: [MusicService]) async {
        sonosDebugLog("[SMAPI] loadServices start (speakerIP=\(speakerIP))")
        do {
            deviceID = try await client.getDeviceID(speakerIP: speakerIP)
            householdID = try await client.getHouseholdID(speakerIP: speakerIP)
            sonosDebugLog("[SMAPI] device identity loaded: deviceID=\(deviceID ?? "<none>") householdID=\(householdID)")
        } catch {
            sonosDiagLog(.error, tag: "SMAPI",
                         "Failed to get device identity: \(error.localizedDescription)",
                         context: ["speakerIP": speakerIP])
        }

        let catalog = MusicServiceCatalog.shared
        catalog.bind(speakerIP: speakerIP)
        await catalog.refresh(speakerIP: speakerIP)
        availableServices = catalog.allDescriptors().map { d in
            SMAPIServiceDescriptor(
                id: d.id, name: d.name, secureUri: d.secureUri,
                authType: d.authType, capabilities: d.capabilities
            )
        }
        sonosDebugLog("[SMAPI] descriptors loaded via catalog: \(availableServices.count) services — \(availableServices.map { "\($0.name)(\($0.id))" }.joined(separator: ", "))")
    }

    /// Known services that don't support third-party AppLink auth
    private static let unsupportedAppLink: Set<Int> = [
        37,  // SiriusXM — returns empty auth URL; same Sonos identity-gate refusal as Amazon / YouTube Music
        144, // Calm Radio — AppLink auth fails; use dedicated browse view instead
        201, // Amazon Music — returns empty auth URL; requires Amazon's own OAuth
        204, // Apple Music — requires native iOS/macOS SDK for OAuth
        284, // YouTube Music — returns empty auth URL; requires Google's own OAuth
        333, // TuneIn (New) — auth polling returns server errors; use existing Sonos account instead
        254, // TuneIn — Anonymous auth, doesn't need AppLink
    ]

    /// Services that support authentication and aren't already authenticated, sorted alphabetically
    public var authenticatableServices: [SMAPIServiceDescriptor] {
        availableServices.filter { svc in
            (svc.authType == "AppLink" || svc.authType == "DeviceLink") &&
            tokenStore.authenticatedServices[svc.id] == nil &&
            !Self.unsupportedAppLink.contains(svc.id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Discovers account serial numbers (sn) from favorites and play history.
    /// The sn= parameter is assigned by the Sonos system when a service is linked
    /// and isn't available through any API — the only way to get it is from
    /// existing content URIs that contain sid= and sn= parameters.
    public func discoverSerialNumbers(using manager: SonosManager) async {
        var snMap: [Int: Int] = [:]

        // Scan Sonos Favorites
        do {
            let (items, _) = try await manager.browse(objectID: BrowseID.favorites, start: 0, count: PageSize.smapiAuth)
            for item in items {
                extractSN(from: item.resourceURI, into: &snMap)
            }
        } catch {
            sonosDiagLog(.warning, tag: "SMAPI",
                         "Failed to scan favorites for serial numbers: \(error.localizedDescription)")
        }

        // Also scan play history URIs as fallback
        if let history = manager.playHistoryManager {
            for entry in history.entries.suffix(PageSize.smapiAuth) {
                extractSN(from: entry.sourceURI, into: &snMap)
            }
        }

        if !snMap.isEmpty {
            serviceSerialNumbers = snMap
            // Log only the count + service IDs, never the serials themselves —
            // those are account-linked identifiers and don't belong in a
            // long-lived debug log.
            sonosDebugLog("[SMAPI] Discovered \(snMap.count) service serial numbers (services=\(snMap.keys.sorted()))")
        } else {
            sonosDebugLog("[SMAPI] No serial numbers found")
        }
    }

    private func extractSN(from uri: String?, into map: inout [Int: Int]) {
        guard let uri else { return }
        let decoded = (uri.removingPercentEncoding ?? uri).replacingOccurrences(of: "&amp;", with: "&")
        guard let sidMatch = decoded.range(of: "sid="),
              let snMatch = decoded.range(of: "sn=") else { return }
        let sidStr = String(decoded[sidMatch.upperBound...].prefix(while: { $0.isNumber }))
        let snStr = String(decoded[snMatch.upperBound...].prefix(while: { $0.isNumber }))
        if let sid = Int(sidStr), let sn = Int(snStr), sn > 0 {
            map[sid] = sn
        }
    }

    /// Gets the account serial number for a service.
    ///
    /// Resolution order: discovered binding (from favorites scan) →
    /// per-service `defaultSerialNumber` from `MusicServiceCatalog` →
    /// generic fallback of `1`.
    ///
    /// Generic fallback is `1` because most SMAPI services reject
    /// SetAVTransportURI with `sn=0` (issue #28 / Radio Paradise — sid
    /// not in the catalog defaulted to 0 and faulted with UPnP 402).
    /// The few services that legitimately use `sn=0` (TuneIn anonymous,
    /// Sonos Radio, Calm Radio) declare `defaultSerialNumber: 0` in
    /// their catalog `ServiceRules`, so the generic-fallback branch
    /// only fires for services the catalog has never seen.
    public func serialNumber(for serviceID: Int) -> Int {
        let discovered = serviceSerialNumbers[serviceID] ?? 0
        if discovered > 0 { return discovered }
        if let rule = MusicServiceCatalog.shared.rules(forSid: serviceID) {
            return rule.defaultSerialNumber
        }
        return 1
    }

    /// Services that are already authenticated (with valid tokens), sorted alphabetically
    public var authenticatedServiceList: [SMAPIServiceDescriptor] {
        availableServices.filter { svc in
            guard let stored = tokenStore.getToken(for: svc.id) else { return false }
            return !stored.authToken.isEmpty
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Authentication Flow

    /// Starts the AppLink authentication flow for a service.
    /// Returns the URL the user needs to visit to authorize.
    public func startAuth(service: SMAPIServiceDescriptor) async -> String? {
        sonosDebugLog("[SMAPI] startAuth tapped: \(service.name) (id=\(service.id), uri=\(service.secureUri))")
        guard let deviceID, !deviceID.isEmpty, !householdID.isEmpty else {
            sonosDebugLog("[SMAPI] startAuth aborted — missing device identity (deviceID=\(deviceID ?? "<nil>") householdID=\(householdID))")
            authError = "Device identity not loaded. Try restarting the app."
            return nil
        }

        isAuthenticating = true
        authServiceName = service.name
        authError = nil

        do {
            let link = try await client.getAppLink(
                serviceURI: service.secureUri,
                householdID: householdID,
                deviceID: deviceID
            )

            if link.regUrl.isEmpty {
                authError = "\(service.name) did not return an authorization URL. This service may not support third-party authentication."
                sonosDiagLog(.error, tag: "SMAPI",
                             "AppLink returned empty regUrl — service likely does not support third-party auth",
                             context: [
                                "service": service.name,
                                "sid": String(service.id),
                                "authType": service.authType
                             ])
                isAuthenticating = false
                return nil
            }

            sonosDebugLog("[SMAPI] Auth started for \(service.name) (linkDeviceId=\(link.linkDeviceId ?? "<none>"))")

            // Start polling for auth completion in background. The session
            // linkDeviceId (if the service minted one — e.g. Plex) must be
            // echoed back verbatim or `getDeviceAuthToken` faults.
            authTask = Task {
                await pollForAuth(service: service, linkCode: link.linkCode, linkDeviceId: link.linkDeviceId)
            }

            return link.regUrl
        } catch {
            authError = "Failed to start authentication: \(error.localizedDescription)"
            sonosDiagLog(.error, tag: "SMAPI",
                         "startAuth threw: \(error.localizedDescription)",
                         context: [
                            "service": service.name,
                            "sid": String(service.id),
                            "authType": service.authType
                         ])
            isAuthenticating = false
            return nil
        }
    }

    private var authTask: Task<Void, Never>?

    /// Cancels an in-progress authentication
    public func cancelAuth() {
        authTask?.cancel()
        authTask = nil
        isAuthenticating = false
        authServiceName = ""
    }

    /// Polls the service for auth completion (user needs to authorize in browser)
    private func pollForAuth(service: SMAPIServiceDescriptor, linkCode: String, linkDeviceId: String?) async {
        guard let deviceID else { return }
        for _ in 0..<60 { // Poll for up to 5 minutes (60 * 5s)
            guard !Task.isCancelled else {
                isAuthenticating = false
                return
            }
            try? await Task.sleep(nanoseconds: Timing.smapiAuthPollInterval)

            do {
                if let result = try await client.getDeviceAuthToken(
                    serviceURI: service.secureUri,
                    householdID: householdID,
                    deviceID: deviceID,
                    linkCode: linkCode,
                    linkDeviceId: linkDeviceId
                ) {
                    // Success!
                    let token = SMAPIToken(
                        serviceID: service.id,
                        serviceName: service.name,
                        authToken: result.authToken,
                        privateKey: result.privateKey,
                        deviceID: deviceID,
                        householdID: householdID
                    )
                    tokenStore.store(token: token)
                    isAuthenticating = false
                    authServiceName = ""
                    sonosDebugLog("[SMAPI] Successfully authenticated \(service.name)")
                    return
                }
                // Not linked yet — continue polling
            } catch {
                sonosDiagLog(.warning, tag: "SMAPI",
                             "Auth poll error: \(error.localizedDescription)",
                             context: [
                                "service": service.name,
                                "sid": String(service.id)
                             ])
            }
        }

        // Timeout
        authError = "Authentication timed out. Please try again."
        sonosDiagLog(.error, tag: "SMAPI",
                     "Authentication timed out after polling window",
                     context: [
                        "service": service.name,
                        "sid": String(service.id)
                     ])
        isAuthenticating = false
    }

    /// Resolves a SMAPI item ID (e.g. `channel:0:2:resume`) to the
    /// direct stream URL the speaker can play via `SetAVTransportURI`.
    ///
    /// Two-stage resolution:
    /// 1. `getMediaURI` — preferred; services that opt in return the
    ///    URL plus optional HTTP headers and timeout.
    /// 2. `getMediaMetadata` — fallback for services that don't
    ///    implement `getMediaURI` (e.g. Radio Paradise: returns
    ///    `Function 'getMediaURI' doesn't exist`). The mediaMetadata
    ///    response usually carries the direct stream URL inline.
    ///
    /// Each stage tries the authenticated form first when Choragus
    /// holds a token, otherwise the anonymous form. Returns `nil`
    /// when both stages fail or yield an empty URI.
    public func resolveMediaURI(serviceID: Int, itemID: String) async throws -> String? {
        guard let descriptor = availableServices.first(where: { $0.id == serviceID }) else {
            return nil
        }
        let serviceURI = descriptor.secureUri
        let token = tokenStore.getToken(for: serviceID)
        let hasToken = (token?.authToken.isEmpty == false)

        // Stage 1 — getMediaURI
        do {
            let url: String
            if hasToken, let t = token {
                url = (try await client.getMediaURI(serviceURI: serviceURI, token: t, id: itemID)).uri
            } else if let deviceID, !deviceID.isEmpty {
                url = (try await client.getMediaURIAnonymous(
                    serviceURI: serviceURI, deviceID: deviceID,
                    householdID: householdID, id: itemID
                )).uri
            } else {
                url = ""
            }
            if !url.isEmpty { return url }
        } catch {
            // Don't propagate — fall through to stage 2. The most
            // common cause is "Function 'getMediaURI' doesn't exist".
        }

        // Stage 2 — getMediaMetadata
        let item: SMAPIMediaItem?
        if hasToken, let t = token {
            item = try await client.getMediaMetadata(serviceURI: serviceURI, token: t, id: itemID)
        } else if let deviceID, !deviceID.isEmpty {
            item = try await client.getMediaMetadataAnonymous(
                serviceURI: serviceURI, deviceID: deviceID,
                householdID: householdID, id: itemID
            )
        } else {
            item = nil
        }
        if let resolved = item?.uri, !resolved.isEmpty { return resolved }
        return nil
    }

    /// Sign out from a service
    public func signOut(serviceID: Int) {
        tokenStore.removeToken(for: serviceID)
        objectWillChange.send()
    }

    // Service-descriptor fetching + parsing now lives in
    // `MusicServiceCatalog` / `MusicServiceCatalogParser`. `loadServices`
    // above delegates to the catalog and reads back the parsed
    // descriptors.
}
