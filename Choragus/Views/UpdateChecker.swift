/// UpdateChecker.swift — Checks the GitHub releases API for a newer version.
///
/// Compares the latest release tag against the running `CFBundleShortVersionString`.
/// A silent check runs at app launch (once per day). A manual check is available
/// from the Help menu and always reports a result, even when up-to-date.
import Foundation
import AppKit
import SonosKit

/// App-level URLs used by the About panel, Help menu, and update checker.
/// Single source of truth — avoids duplicating the repository path across files.
enum AppLinks {
    static let repositoryURLString = "https://github.com/scottwaters/Choragus"
    static let issuesURLString = "https://github.com/scottwaters/Choragus/issues/new"
    static let releasesAPIURLString = "https://api.github.com/repos/scottwaters/Choragus/releases/latest"

    static var repositoryURL: URL? { URL(string: repositoryURLString) }
    static var issuesURL: URL? { URL(string: issuesURLString) }
    static var releasesAPIURL: URL? { URL(string: releasesAPIURLString) }
}

@MainActor
final class UpdateChecker {
    static let shared = UpdateChecker()

    private let lastCheckKey = "updateChecker.lastCheck"
    private let checkIntervalSeconds: TimeInterval = 86_400 // 24h

    private init() {}

    /// Runs a silent check at most once per 24h. Shows a dialog only when a newer
    /// release is available. Use for automatic app-launch checks.
    func checkInBackgroundIfDue() {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - last >= checkIntervalSeconds else { return }
        UserDefaults.standard.set(now, forKey: lastCheckKey)
        Task { await performCheck(silentWhenCurrent: true) }
    }

    /// User-initiated check from Help menu. Always reports a result.
    func checkNow() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        Task { await performCheck(silentWhenCurrent: false) }
    }

    // MARK: - Implementation

    /// GitHub release payload. Only the fields we use are decoded.
    /// `/releases/latest` already filters out draft/prerelease, so we don't check those flags.
    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let body: String?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body
        }
    }

    private func performCheck(silentWhenCurrent: Bool) async {
        guard let url = AppLinks.releasesAPIURL else { return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                let message = "GitHub returned HTTP \(http.statusCode)."
                sonosDebugLog("[UPDATE] \(message)")
                if !silentWhenCurrent { await showError(message) }
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let remote = normalize(release.tagName)
            let local = normalize(currentVersion())
            switch compareSemver(local: local, remote: remote) {
            case .orderedAscending:
                sonosDebugLog("[UPDATE] Update available: local=\(local) remote=\(remote)")
                await showUpdateAvailable(current: local, latest: remote, url: release.htmlURL, notes: release.body)
            case .orderedSame, .orderedDescending:
                sonosDebugLog("[UPDATE] Up to date: local=\(local) remote=\(remote)")
                if !silentWhenCurrent { await showUpToDate() }
            }
        } catch {
            sonosDebugLog("[UPDATE] Check failed: \(error.localizedDescription)")
            if !silentWhenCurrent { await showError(error.localizedDescription) }
        }
    }

    private func currentVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
    }

    /// Strips a leading "v" and any build suffix. "v3.1-beta" → "3.1".
    private func normalize(_ version: String) -> String {
        var s = version.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Stop at first non-dot / non-digit
        var out = ""
        for ch in s {
            if ch.isNumber || ch == "." { out.append(ch) } else { break }
        }
        return out.isEmpty ? s : out
    }

    /// Numeric comparison of dot-separated versions. "3.1" < "3.1.1" < "3.2" < "10.0".
    private func compareSemver(local: String, remote: String) -> ComparisonResult {
        let lp = local.split(separator: ".").map { Int($0) ?? 0 }
        let rp = remote.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lp.count, rp.count)
        for i in 0..<count {
            let l = i < lp.count ? lp[i] : 0
            let r = i < rp.count ? rp[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    // MARK: - UI

    private func showUpdateAvailable(current: String, latest: String, url: String, notes: String?) async {
        let alert = NSAlert()
        alert.messageText = L10n.updateAvailableTitle
        var informative = L10n.updateAvailableBody(current: current, latest: latest)
        if let notes, !notes.isEmpty {
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = trimmed.count > 400 ? String(trimmed.prefix(400)) + "\u{2026}" : trimmed
            informative += "\n\n\(L10n.releaseNotesLabel)\n\(snippet)"
        }
        alert.informativeText = informative
        alert.addButton(withTitle: L10n.viewOnGitHub)
        alert.addButton(withTitle: L10n.later)
        alert.alertStyle = .informational
        let response = alert.runModal()
        if response == .alertFirstButtonReturn, let link = URL(string: url) {
            NSWorkspace.shared.open(link)
        }
    }

    private func showUpToDate() async {
        let alert = NSAlert()
        alert.messageText = L10n.upToDateTitle
        alert.informativeText = L10n.upToDateBody(version: currentVersion())
        alert.addButton(withTitle: L10n.ok)
        alert.alertStyle = .informational
        alert.runModal()
    }

    private func showError(_ message: String) async {
        let alert = NSAlert()
        alert.messageText = L10n.updateCheckFailedTitle
        alert.informativeText = message
        alert.addButton(withTitle: L10n.ok)
        alert.alertStyle = .warning
        alert.runModal()
    }
}
