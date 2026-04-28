/// ITunesRateLimiter.swift — Single chokepoint for every call to itunes.apple.com.
///
/// Apple's iTunes Search API has an undocumented rate limit (~20 requests per
/// minute per IP). Crossing it returns HTTP 403 silently and locks the IP out
/// for tens of minutes. The previous code retried per call site, so a single
/// stuck track could fan out to hundreds of 403s and deepen the cooldown.
///
/// This actor sits in front of every iTunes call:
///
/// 1. **Self-throttle.** Sliding 60-second window caps us at `softLimitPerMinute`,
///    well under Apple's threshold. Calls past the window return `.denied` instead
///    of hitting the network. Prevents the 403 from happening in the first place.
///
/// 2. **Hard cooldown on 403/429.** When Apple does say no, every iTunes call
///    short-circuits for `cooldownDuration` (15 min). Avoids piling on while the
///    block is in effect.
///
/// 3. **Telemetry.** `snapshot()` exposes counts and current state for the UI
///    so users see "Apple Music search temporarily unavailable" instead of a
///    silent empty result list.
import Foundation

public actor ITunesRateLimiter {
    public static let shared = ITunesRateLimiter()

    // MARK: - Tunables

    /// Self-imposed cap. Empirically Apple's window is ~20/min — we stay
    /// conservatively under so we never trip the 403.
    private let softLimitPerMinute = 12
    private let windowDuration: TimeInterval = 60

    /// How long we treat ourselves as locked out after a 403/429. Apple's
    /// actual block typically clears in 10–30 min; 15 is a reasonable middle
    /// ground that errs on the side of letting the IP fully reset.
    private let cooldownDuration: TimeInterval = 15 * 60

    // MARK: - State

    /// Sliding window of request timestamps used by the self-throttle.
    private var requestWindow: [Date] = []
    /// Set to a future date when a 403/429 puts us in hard cooldown.
    private var cooldownUntil: Date?
    /// The HTTP status that triggered the current cooldown (403 vs 429),
    /// surfaced for diagnostics.
    private var cooldownStatus: Int?

    // Cumulative counters since process start. Reset only by app relaunch.
    private var totalAttempted: Int = 0
    private var totalAllowed: Int = 0
    private var totalDeniedSelfThrottle: Int = 0
    private var totalDeniedCooldown: Int = 0
    private var total403s: Int = 0
    private var total429s: Int = 0
    private var totalNetworkErrors: Int = 0

    public init() {}

    // MARK: - Decision API

    public enum Decision: Equatable {
        case proceed
        case denied(reason: DenyReason, retryAfter: Date)
    }

    public enum DenyReason: Equatable {
        /// We've hit our self-imposed window cap; would-be 403 prevented locally.
        case selfThrottle
        /// Apple already returned 403/429 and we're waiting it out.
        case cooldown(status: Int)
    }

    /// Atomic acquire — returns `.proceed` and records the request, or `.denied`
    /// with a `retryAfter` time the caller can surface to the user.
    public func acquire() -> Decision {
        totalAttempted += 1
        let now = Date()

        if let until = cooldownUntil {
            if now < until {
                totalDeniedCooldown += 1
                return .denied(
                    reason: .cooldown(status: cooldownStatus ?? 403),
                    retryAfter: until
                )
            } else {
                // Cooldown expired — clear it and continue
                cooldownUntil = nil
                cooldownStatus = nil
            }
        }

        // Drop timestamps that fell out of the window
        requestWindow.removeAll { now.timeIntervalSince($0) >= windowDuration }

        if requestWindow.count >= softLimitPerMinute {
            totalDeniedSelfThrottle += 1
            // Earliest in-window timestamp + window = when a slot frees up
            let oldest = requestWindow.first ?? now
            return .denied(
                reason: .selfThrottle,
                retryAfter: oldest.addingTimeInterval(windowDuration)
            )
        }

        requestWindow.append(now)
        totalAllowed += 1
        return .proceed
    }

    /// Caller invokes this after observing a 403 or 429 from iTunes. Locks the
    /// gate for `cooldownDuration`.
    public func record(failureStatus status: Int) {
        if status == 403 { total403s += 1 }
        if status == 429 { total429s += 1 }
        cooldownUntil = Date().addingTimeInterval(cooldownDuration)
        cooldownStatus = status
        sonosDebugLog("[iTunes] HTTP \(status) — entering \(Int(cooldownDuration))s cooldown until \(cooldownUntil!)")
    }

    public func recordNetworkError() {
        totalNetworkErrors += 1
    }

    /// Waits up to `maxWait` seconds for a slot to free up under self-throttle.
    /// Fails fast on hard `.cooldown` (15-minute waits would just stall callers).
    ///
    /// Behaviour:
    /// - `.proceed` — slot acquired, return immediately.
    /// - `.denied(.cooldown)` — return immediately (caller decides what to do).
    /// - `.denied(.selfThrottle)` — sleep until `retryAfter` (plus tiny jitter to
    ///   avoid thundering-herd wake-ups), then retry. Bails out and surfaces the
    ///   denial if total wait would exceed `maxWait`.
    ///
    /// Used by background sweeps (history backfill, browse panel rendering)
    /// that benefit from automatic pacing across the soft window. Foreground
    /// user-initiated calls should keep using `acquire()` for fail-fast UX.
    public func acquireOrWait(maxWait: TimeInterval) async -> Decision {
        let deadline = Date().addingTimeInterval(maxWait)
        while true {
            let decision = acquire()
            switch decision {
            case .proceed:
                return .proceed
            case .denied(.cooldown, _):
                return decision
            case .denied(.selfThrottle, let until):
                if until > deadline {
                    return decision
                }
                // Small jitter so concurrent waiters don't all wake on the same tick.
                let waitInterval = max(0.05, until.timeIntervalSinceNow + Double.random(in: 0...0.25))
                try? await Task.sleep(nanoseconds: UInt64(waitInterval * 1_000_000_000))
                if Task.isCancelled {
                    return decision
                }
            }
        }
    }

    // MARK: - Convenience: end-to-end gated request

    /// Wraps the gate + URLSession round-trip. Returns `nil` for:
    /// - `.denied` from the gate (caller should not hit the network)
    /// - non-2xx HTTP response (and triggers cooldown for 403/429)
    /// - URLSession network errors
    ///
    /// `maxWait`:
    /// - `0` (default) — fail fast on any denial. Right for foreground calls
    ///   where empty results beat a stalled UI.
    /// - `> 0` — sleep up to that many seconds on `.selfThrottle` so bursty
    ///   workloads (browse-panel render, history backfill) pace themselves
    ///   into the rate-limit window automatically. Hard `.cooldown` still
    ///   fails fast — 15-minute waits would just stall callers.
    /// Foreground-search variant: skips the per-minute self-throttle but
    /// still respects an active 403/429 cooldown and records new ones.
    /// Use this for user-initiated calls (Apple Music search, manual
    /// "Search Artwork" sheet) where silent empty results are unacceptable
    /// — these don't share the budget that protects opportunistic
    /// background art enrichment.
    ///
    /// Returns nil during cooldown so the caller can surface a clear
    /// "Apple Music temporarily unavailable" message; the cooldown is
    /// initiated by Apple itself, not by us.
    public func performUnthrottled(url: URL, session: URLSession) async -> (Data, HTTPURLResponse)? {
        let now = Date()
        if let until = cooldownUntil, now < until {
            totalDeniedCooldown += 1
            sonosDebugLog("[iTunes] cooldown(\(cooldownStatus ?? 403)) deny (unthrottled) until \(until): \(url.absoluteString.prefix(120))")
            return nil
        }
        // Count the call against the soft window so the limiter's view
        // of activity is accurate, but DON'T deny on cap — just record.
        requestWindow.append(now)
        totalAllowed += 1
        totalAttempted += 1

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 403 || http.statusCode == 429 {
                record(failureStatus: http.statusCode)
                return nil
            }
            guard (200..<300).contains(http.statusCode) else {
                return nil
            }
            return (data, http)
        } catch {
            recordNetworkError()
            return nil
        }
    }

    public func perform(url: URL, session: URLSession, maxWait: TimeInterval = 0) async -> (Data, HTTPURLResponse)? {
        let decision: Decision = maxWait > 0
            ? await acquireOrWait(maxWait: maxWait)
            : acquire()

        switch decision {
        case .denied(let reason, let until):
            let urlSummary = url.absoluteString.prefix(120)
            switch reason {
            case .selfThrottle:
                sonosDebugLog("[iTunes] self-throttle deny (waited up to \(Int(maxWait))s) until \(until): \(urlSummary)")
            case .cooldown(let status):
                sonosDebugLog("[iTunes] cooldown(\(status)) deny until \(until): \(urlSummary)")
            }
            return nil
        case .proceed:
            break
        }

        do {
            let (data, response) = try await session.data(for: URLRequest(url: url))
            guard let http = response as? HTTPURLResponse else {
                return nil
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                record(failureStatus: http.statusCode)
                return nil
            }
            guard (200..<300).contains(http.statusCode) else {
                return nil
            }
            return (data, http)
        } catch {
            recordNetworkError()
            return nil
        }
    }

    // MARK: - Telemetry

    public struct Snapshot: Sendable, Equatable {
        public let isAvailable: Bool
        public let cooldownUntil: Date?
        public let cooldownStatus: Int?
        public let requestsInWindow: Int
        public let softLimit: Int
        public let totalAttempted: Int
        public let totalAllowed: Int
        public let totalDeniedSelfThrottle: Int
        public let totalDeniedCooldown: Int
        public let total403s: Int
        public let total429s: Int
        public let totalNetworkErrors: Int
    }

    public func snapshot() -> Snapshot {
        let now = Date()
        let isAvailable = (cooldownUntil ?? .distantPast) <= now
        let activeRequests = requestWindow.filter { now.timeIntervalSince($0) < windowDuration }.count
        return Snapshot(
            isAvailable: isAvailable,
            cooldownUntil: isAvailable ? nil : cooldownUntil,
            cooldownStatus: isAvailable ? nil : cooldownStatus,
            requestsInWindow: activeRequests,
            softLimit: softLimitPerMinute,
            totalAttempted: totalAttempted,
            totalAllowed: totalAllowed,
            totalDeniedSelfThrottle: totalDeniedSelfThrottle,
            totalDeniedCooldown: totalDeniedCooldown,
            total403s: total403s,
            total429s: total429s,
            totalNetworkErrors: totalNetworkErrors
        )
    }
}
