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
        get { UserDefaults.standard.bool(forKey: "smapiEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "smapiEnabled"); objectWillChange.send() }
    }

    private var deviceID = ""
    private var householdID = ""

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
        204, // Apple Music — requires native iOS/macOS SDK for OAuth
    ]

    /// Services that support authentication and aren't already authenticated
    public var authenticatableServices: [SMAPIServiceDescriptor] {
        availableServices.filter { svc in
            (svc.authType == "AppLink" || svc.authType == "DeviceLink") &&
            tokenStore.authenticatedServices[svc.id] == nil &&
            !Self.unsupportedAppLink.contains(svc.id)
        }
    }

    /// Discovers account serial numbers (sn) from existing favorites
    public func discoverSerialNumbers(using manager: SonosManager) async {
        do {
            let (items, _) = try await manager.browse(objectID: "FV:2", start: 0, count: 100)
            var snMap: [Int: Int] = [:]
            for item in items {
                guard let uri = item.resourceURI else { continue }
                let decoded = (uri.removingPercentEncoding ?? uri).replacingOccurrences(of: "&amp;", with: "&")
                if let sidMatch = decoded.range(of: "sid="),
                   let snMatch = decoded.range(of: "sn=") {
                    let sidStr = String(decoded[sidMatch.upperBound...].prefix(while: { $0.isNumber }))
                    let snStr = String(decoded[snMatch.upperBound...].prefix(while: { $0.isNumber }))
                    if let sid = Int(sidStr), let sn = Int(snStr), sn > 0 {
                        snMap[sid] = sn
                    }
                }
            }
            if !snMap.isEmpty {
                serviceSerialNumbers = snMap
                sonosDebugLog("[SMAPI] Discovered sn map: \(snMap)")
            }
        } catch {
            sonosDebugLog("[SMAPI] Failed to discover serial numbers: \(error)")
        }
    }

    /// Gets the account serial number for a service, defaulting to 0
    public func serialNumber(for serviceID: Int) -> Int {
        serviceSerialNumbers[serviceID] ?? 0
    }

    /// Services that are already authenticated
    public var authenticatedServiceList: [SMAPIServiceDescriptor] {
        availableServices.filter { tokenStore.authenticatedServices[$0.id] != nil }
    }

    // MARK: - Authentication Flow

    /// Starts the AppLink authentication flow for a service.
    /// Returns the URL the user needs to visit to authorize.
    public func startAuth(service: SMAPIServiceDescriptor) async -> String? {
        guard !deviceID.isEmpty, !householdID.isEmpty else {
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

            sonosDebugLog("[SMAPI] Auth URL for \(service.name): \(regUrl)")
            sonosDebugLog("[SMAPI] Link code: \(linkCode)")

            // Start polling for auth completion in background
            Task {
                await pollForAuth(service: service, linkCode: linkCode)
            }

            return regUrl
        } catch {
            authError = "Failed to start authentication: \(error.localizedDescription)"
            isAuthenticating = false
            return nil
        }
    }

    /// Polls the service for auth completion (user needs to authorize in browser)
    private func pollForAuth(service: SMAPIServiceDescriptor, linkCode: String) async {
        for _ in 0..<60 { // Poll for up to 5 minutes (60 * 5s)
            try? await Task.sleep(nanoseconds: 5_000_000_000)

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
        var request = URLRequest(url: URL(string: "http://\(speakerIP):1400/MusicServices/Control")!)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:MusicServices:1#ListAvailableServices\"", forHTTPHeaderField: "SOAPAction")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseServiceDescriptors(_ xml: String) -> [SMAPIServiceDescriptor] {
        let unescaped = xml
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")

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
