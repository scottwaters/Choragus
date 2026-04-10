/// EventSubscriptionManager.swift — Manages UPnP event subscription lifecycle.
///
/// Handles SUBSCRIBE, RENEW, and UNSUBSCRIBE for Sonos UPnP services.
/// Subscriptions have a 30-minute TTL and are renewed at 80% of their timeout.
/// Tracks active subscriptions and provides health status.
import Foundation

public struct EventSubscription: Sendable {
    public let sid: String          // Subscription ID from Sonos
    public let deviceID: String
    public let deviceIP: String
    public let devicePort: Int
    public let servicePath: String
    public let timeout: TimeInterval
    public let subscribedAt: Date

    public var expiresAt: Date {
        subscribedAt.addingTimeInterval(timeout)
    }

    public var renewAt: Date {
        subscribedAt.addingTimeInterval(timeout * 0.8)
    }

    public var isExpired: Bool {
        Date() > expiresAt
    }
}

public final class EventSubscriptionManager: @unchecked Sendable {
    private let session: URLSession
    private var subscriptions: [String: EventSubscription] = [:]  // keyed by SID
    private let lock = NSLock()
    private var renewalTask: Task<Void, Never>?
    private let callbackURL: URL

    /// All active subscription IDs
    public var activeSubscriptionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.count
    }

    public var activeSIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(subscriptions.keys)
    }

    public var allSubscriptions: [EventSubscription] {
        lock.lock()
        defer { lock.unlock() }
        return Array(subscriptions.values)
    }

    public init(callbackURL: URL) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = URLSession(configuration: config)
        self.callbackURL = callbackURL
    }

    // MARK: - Subscribe

    /// Subscribes to a UPnP service on a Sonos device.
    /// Returns the subscription or throws on failure.
    public func subscribe(device: SonosDevice, servicePath: String) async throws -> EventSubscription {
        let eventPath = servicePath.replacingOccurrences(of: "/Control", with: "/Event")
        let urlString = "http://\(device.ip):\(device.port)\(eventPath)"
        guard let url = URL(string: urlString) else {
            throw EventSubscriptionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "SUBSCRIBE"
        request.setValue("<\(callbackURL.absoluteString)>", forHTTPHeaderField: "CALLBACK")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("Second-1800", forHTTPHeaderField: "TIMEOUT")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw EventSubscriptionError.subscribeFailed(code)
        }

        guard let sid = httpResponse.value(forHTTPHeaderField: "SID") else {
            throw EventSubscriptionError.noSID
        }

        // Parse timeout from response (e.g. "Second-1800")
        let timeout: TimeInterval
        if let timeoutHeader = httpResponse.value(forHTTPHeaderField: "TIMEOUT"),
           let seconds = Self.parseTimeout(timeoutHeader) {
            timeout = seconds
        } else {
            timeout = 1800
        }

        let subscription = EventSubscription(
            sid: sid,
            deviceID: device.id,
            deviceIP: device.ip,
            devicePort: device.port,
            servicePath: servicePath,
            timeout: timeout,
            subscribedAt: Date()
        )

        lock.lock()
        defer { lock.unlock() }
        subscriptions[sid] = subscription
        return subscription
    }

    // MARK: - Renew

    public func renew(_ subscription: EventSubscription) async throws -> EventSubscription {
        let eventPath = subscription.servicePath.replacingOccurrences(of: "/Control", with: "/Event")
        let urlString = "http://\(subscription.deviceIP):\(subscription.devicePort)\(eventPath)"
        guard let url = URL(string: urlString) else {
            throw EventSubscriptionError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "SUBSCRIBE"
        request.setValue(subscription.sid, forHTTPHeaderField: "SID")
        request.setValue("Second-1800", forHTTPHeaderField: "TIMEOUT")

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EventSubscriptionError.renewFailed(0)
        }

        // 412 means SID is invalid — need fresh subscribe
        if httpResponse.statusCode == 412 {
            lock.lock()
            defer { lock.unlock() }
            subscriptions.removeValue(forKey: subscription.sid)
            throw EventSubscriptionError.subscriptionExpired
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw EventSubscriptionError.renewFailed(httpResponse.statusCode)
        }

        let timeout: TimeInterval
        if let timeoutHeader = httpResponse.value(forHTTPHeaderField: "TIMEOUT"),
           let seconds = Self.parseTimeout(timeoutHeader) {
            timeout = seconds
        } else {
            timeout = subscription.timeout
        }

        let renewed = EventSubscription(
            sid: subscription.sid,
            deviceID: subscription.deviceID,
            deviceIP: subscription.deviceIP,
            devicePort: subscription.devicePort,
            servicePath: subscription.servicePath,
            timeout: timeout,
            subscribedAt: Date()
        )

        lock.lock()
        defer { lock.unlock() }
        subscriptions[subscription.sid] = renewed
        return renewed
    }

    // MARK: - Unsubscribe

    public func unsubscribe(_ subscription: EventSubscription) async {
        let eventPath = subscription.servicePath.replacingOccurrences(of: "/Control", with: "/Event")
        let urlString = "http://\(subscription.deviceIP):\(subscription.devicePort)\(eventPath)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "UNSUBSCRIBE"
        request.setValue(subscription.sid, forHTTPHeaderField: "SID")

        _ = try? await session.data(for: request)
        lock.lock()
        defer { lock.unlock() }
        subscriptions.removeValue(forKey: subscription.sid)
    }

    public func unsubscribeAll() async {
        let allSubs: [EventSubscription]
        lock.lock()
        allSubs = Array(subscriptions.values)
        lock.unlock()
        for sub in allSubs {
            await unsubscribe(sub)
        }
        stopRenewalLoop()
    }

    // MARK: - Renewal Loop

    /// Starts a background loop that renews subscriptions before they expire.
    /// Checks every 60 seconds for subscriptions approaching their renewal time.
    public func startRenewalLoop(onRenewalFailed: @escaping (EventSubscription) -> Void) {
        stopRenewalLoop()
        renewalTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Timing.subscriptionRenewalCheck))

                let now = Date()
                let currentSubs: [EventSubscription]
                self.lock.lock()
                currentSubs = Array(self.subscriptions.values)
                self.lock.unlock()
                for sub in currentSubs {
                    guard !Task.isCancelled else { return }
                    if now > sub.renewAt {
                        do {
                            _ = try await renew(sub)
                        } catch {
                            self.lock.lock()
                            defer { self.lock.unlock() }
                            self.subscriptions.removeValue(forKey: sub.sid)
                            onRenewalFailed(sub)
                        }
                    }
                }
            }
        }
    }

    public func stopRenewalLoop() {
        renewalTask?.cancel()
        renewalTask = nil
    }

    /// Returns the subscription matching a given SID
    public func subscription(for sid: String) -> EventSubscription? {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions[sid]
    }

    /// Returns subscriptions for a given device
    public func subscriptions(for deviceID: String) -> [EventSubscription] {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.values.filter { $0.deviceID == deviceID }
    }

    // MARK: - Helpers

    /// Parses "Second-1800" or "Second-infinite" into seconds
    private static func parseTimeout(_ header: String) -> TimeInterval? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "second-infinite" {
            return 86400 // treat as 24 hours
        }
        if trimmed.lowercased().hasPrefix("second-"),
           let seconds = Double(trimmed.dropFirst(7)) {
            return seconds
        }
        return nil
    }
}

public enum EventSubscriptionError: Error, LocalizedError {
    case invalidURL
    case subscribeFailed(Int)
    case renewFailed(Int)
    case noSID
    case subscriptionExpired

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid subscription URL"
        case .subscribeFailed(let code): return "Subscribe failed with HTTP \(code)"
        case .renewFailed(let code): return "Renewal failed with HTTP \(code)"
        case .noSID: return "No SID in subscription response"
        case .subscriptionExpired: return "Subscription expired (412)"
        }
    }
}
