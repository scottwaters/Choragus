/// SMAPIAuthManager.swift — Manages SMAPI authentication flow and service discovery.
import Foundation

@MainActor
public final class SMAPIAuthManager: ObservableObject {
    public let client = SMAPIClient()
    public let tokenStore = SMAPITokenStore()

    @Published public var availableServices: [SMAPIServiceDescriptor] = []
    @Published public var isAuthenticating = false
    @Published public var authServiceName = ""
    @Published public var authError: String?

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: UDKey.smapiEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: UDKey.smapiEnabled); objectWillChange.send() }
    }

    public private(set) var deviceID: String?
    public private(set) var householdID = ""

    /// Maps service ID to account serial number (sn) extracted from favorites/history
    @Published public var serviceSerialNumbers: [Int: Int] = [:]

    public init() {
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

    // MARK: - Service Discovery

    /// Loads available services and device identity from a speaker
    public func loadServices(speakerIP: String, musicServicesList: [MusicService]) async {
        do {
            deviceID = try await client.getDeviceID(speakerIP: speakerIP)
            householdID = try await client.getHouseholdID(speakerIP: speakerIP)
        } catch {
            sonosDebugLog("[SMAPI] Failed to get device identity: \(error)")
        }

        // Build service descriptors from the MusicServices list
        // We need the SecureUri which isn't in the basic list — fetch full descriptor
        do {
            let descriptorXML = try await fetchServiceDescriptors(speakerIP: speakerIP)
            availableServices = parseServiceDescriptors(descriptorXML)
        } catch {
            sonosDebugLog("[SMAPI] Failed to load service descriptors: \(error)")
        }
    }

    /// Known services that don't support third-party AppLink auth
    private static let unsupportedAppLink: Set<Int> = [
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
            sonosDebugLog("[SMAPI] Failed to scan favorites for serial numbers: \(error)")
        }

        // Also scan play history URIs as fallback
        if let history = manager.playHistoryManager {
            for entry in history.entries.suffix(PageSize.smapiAuth) {
                extractSN(from: entry.sourceURI, into: &snMap)
            }
        }

        if !snMap.isEmpty {
            serviceSerialNumbers = snMap
            sonosDebugLog("[SMAPI] Discovered \(snMap.count) service serial numbers: \(snMap)")
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
    /// Defaults to 1 for subscription services (Apple Music, Spotify, etc.) when
    /// no sn has been discovered yet — sn=0 causes auth failures on most services,
    /// and sn=1 works for the common single-account setup.
    public func serialNumber(for serviceID: Int) -> Int {
        let sn = serviceSerialNumbers[serviceID] ?? 0
        if sn == 0 {
            switch serviceID {
            case ServiceID.appleMusic, ServiceID.spotify, ServiceID.amazonMusic,
                 ServiceID.tidal, ServiceID.deezer, ServiceID.qobuz, ServiceID.soundCloud,
                 ServiceID.youTubeMusic:
                return 1
            default:
                return 0
            }
        }
        return sn
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
        guard let deviceID, !deviceID.isEmpty, !householdID.isEmpty else {
            authError = "Device identity not loaded. Try restarting the app."
            return nil
        }

        isAuthenticating = true
        authServiceName = service.name
        authError = nil

        do {
            let (regUrl, linkCode) = try await client.getAppLink(
                serviceURI: service.secureUri,
                householdID: householdID,
                deviceID: deviceID
            )

            if regUrl.isEmpty {
                authError = "\(service.name) did not return an authorization URL. This service may not support third-party authentication."
                isAuthenticating = false
                return nil
            }

            sonosDebugLog("[SMAPI] Auth started for \(service.name)")

            // Start polling for auth completion in background
            authTask = Task {
                await pollForAuth(service: service, linkCode: linkCode)
            }

            return regUrl
        } catch {
            authError = "Failed to start authentication: \(error.localizedDescription)"
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
    private func pollForAuth(service: SMAPIServiceDescriptor, linkCode: String) async {
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
                    linkCode: linkCode
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
                sonosDebugLog("[SMAPI] Auth poll error: \(error.localizedDescription)")
            }
        }

        // Timeout
        authError = "Authentication timed out. Please try again."
        isAuthenticating = false
    }

    /// Sign out from a service
    public func signOut(serviceID: Int) {
        tokenStore.removeToken(for: serviceID)
        objectWillChange.send()
    }

    // MARK: - Service Descriptor Parsing

    private func fetchServiceDescriptors(speakerIP: String) async throws -> String {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
         s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body>
        <u:ListAvailableServices xmlns:u="urn:schemas-upnp-org:service:MusicServices:1"/>
        </s:Body></s:Envelope>
        """
        let port = SonosProtocol.defaultPort
        guard let url = URL(string: "http://\(speakerIP):\(port)/MusicServices/Control") else { return "" }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:MusicServices:1#ListAvailableServices\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseServiceDescriptors(_ xml: String) -> [SMAPIServiceDescriptor] {
        let unescaped = XMLResponseParser.xmlUnescape(xml)

        var services: [SMAPIServiceDescriptor] = []
        let parts = unescaped.components(separatedBy: "<Service ")
        for part in parts.dropFirst() {
            guard let idStr = extractAttr(part, "Id"),
                  let id = Int(idStr),
                  let name = extractAttr(part, "Name"),
                  let secureUri = extractAttr(part, "SecureUri") else { continue }

            var authType = "Anonymous"
            if let policyRange = part.range(of: "Auth=\""),
               let endQuote = part[policyRange.upperBound...].range(of: "\"") {
                authType = String(part[policyRange.upperBound..<endQuote.lowerBound])
            }

            let capabilities = Int(extractAttr(part, "Capabilities") ?? "0") ?? 0

            services.append(SMAPIServiceDescriptor(
                id: id, name: name, secureUri: secureUri,
                authType: authType, capabilities: capabilities
            ))
        }
        return services.sorted { $0.name < $1.name }
    }

    private func extractAttr(_ text: String, _ name: String) -> String? {
        guard let range = text.range(of: "\(name)=\""),
              let endQuote = text[range.upperBound...].range(of: "\"") else { return nil }
        return String(text[range.upperBound..<endQuote.lowerBound])
    }
}
