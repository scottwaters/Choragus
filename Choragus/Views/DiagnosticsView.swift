/// Diagnostics window — table of recent redacted log events plus
/// copy / save actions so users can attach the bundle to a GitHub
/// issue without exposing private information.
import SwiftUI
import SonosKit
import AppKit

struct DiagnosticsView: View {
    @EnvironmentObject var sonosManager: SonosManager
    @EnvironmentObject var liveLog: LiveEventLog
    @State private var entries: [DiagnosticEntry] = []
    @State private var levelFilter: LevelFilter = .all
    @State private var copied = false
    @State private var saveError: String?
    @State private var selection: Set<Int64> = []
    @State private var activeTab: Tab = .log

    /// Pending encrypted-bundle preview state. When non-nil the
    /// preview sheet is shown; user confirmation triggers the
    /// encryption + write + reveal flow.
    @State private var pendingEncryptedReport: PendingEncryptedReport?
    @State private var encryptedReportError: String?

    enum EncryptedReportTarget {
        case publicIssue
        case privateAdvisory
    }

    struct PendingEncryptedReport: Identifiable {
        let id = UUID()
        let target: EncryptedReportTarget
        let rows: [DiagnosticEntry]
        let bundleText: String
    }

    enum Tab: String, CaseIterable, Identifiable {
        case log, liveEvents
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .log:        return L10n.diagTabLog
            case .liveEvents: return L10n.diagTabLiveEvents
            }
        }
    }

    enum LevelFilter: String, CaseIterable, Identifiable {
        case all, errorsOnly, warningsAndErrors
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .all: return L10n.diagFilterAll
            case .errorsOnly: return L10n.diagFilterErrors
            case .warningsAndErrors: return L10n.diagFilterWarningsAndErrors
            }
        }
    }

    private var filteredEntries: [DiagnosticEntry] {
        switch levelFilter {
        case .all: return entries
        case .errorsOnly: return entries.filter { $0.level == .error }
        case .warningsAndErrors: return entries.filter { $0.level == .warning || $0.level == .error }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabPicker
            Divider()
            switch activeTab {
            case .log:
                logTab
            case .liveEvents:
                LiveEventsView()
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { reload() }
        .sheet(item: $pendingEncryptedReport) { pending in
            previewSheet(for: pending)
        }
        .alert(L10n.diagEncryptedReportFailedTitle,
               isPresented: Binding(
                   get: { encryptedReportError != nil },
                   set: { if !$0 { encryptedReportError = nil } }
               ),
               actions: {
                   Button(L10n.ok) { encryptedReportError = nil }
               },
               message: {
                   Text(encryptedReportError ?? "")
               })
    }

    private var tabPicker: some View {
        Picker("", selection: $activeTab) {
            ForEach(Tab.allCases) { Text($0.displayName).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var logTab: some View {
        VStack(spacing: 0) {
            header
            Divider()
            helpBanner
            Divider()
            table
            Divider()
            footer
        }
    }

    private var helpBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.tint)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.diagHelpTitle)
                    .font(.headline)
                Text(L10n.diagHelpBody)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.06))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("", selection: $levelFilter) {
                ForEach(LevelFilter.allCases) { f in
                    Text(f.displayName).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 360)

            Spacer()

            Text(L10n.diagEntriesCountFormat(filteredEntries.count, entries.count))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L10n.refresh)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var table: some View {
        Table(filteredEntries, selection: $selection) {
            TableColumn(L10n.diagColumnTime) { entry in
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 130, ideal: 150, max: 180)

            TableColumn(L10n.diagColumnLevel) { entry in
                levelBadge(entry.level)
            }
            .width(min: 70, ideal: 80, max: 100)

            TableColumn(L10n.diagColumnTag) { entry in
                Text(entry.tag)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 100, max: 140)

            TableColumn(L10n.diagColumnMessage) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.message)
                        .font(.callout)
                    if let ctx = entry.contextJSON, !ctx.isEmpty {
                        Text(ctx)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .contextMenu(forSelectionType: Int64.self) { ids in
            if !ids.isEmpty {
                Button(ids.count == 1
                       ? L10n.diagCopyRow
                       : L10n.diagCopyRowsFormat(ids.count)) {
                    copyRows(ids: ids)
                }
                Divider()
                Button(ids.count == 1
                       ? L10n.diagCopyRowWithPayload
                       : L10n.diagCopyRowsWithPayloadFormat(ids.count)) {
                    copyRowsWithPayload(ids: ids)
                }
                .help(L10n.diagCopyRowWithPayloadHelp)
            }
        } primaryAction: { _ in
            // Double-click currently does nothing — context menu for copy.
        }
    }

    @ViewBuilder
    private func levelBadge(_ level: DiagnosticLevel) -> some View {
        // `.debug` entries are dropped by `DiagnosticsService.log` and
        // never reach this view, but the switch must stay exhaustive
        // so the enum can grow new cases without surprise compile
        // errors.
        let (color, label): (Color, String) = {
            switch level {
            case .debug: return (Color.gray.opacity(0.6), "Debug")
            case .info: return (.secondary, L10n.diagLevelInfo)
            case .warning: return (.orange, L10n.diagLevelWarning)
            case .error: return (.red, L10n.diagLevelError)
            }
        }()
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                copyAll()
            } label: {
                Label(copied ? L10n.copied : L10n.diagCopyAll,
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)

            Button {
                saveBundle()
            } label: {
                Label(L10n.diagSaveBundle, systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)

            // Encrypted bundle to a user-chosen location. Mirrors the
            // ReportBug encrypted flow's bundle assembly but skips the
            // forced Downloads write + GitHub open, so the user can
            // share the file out-of-band (email, Slack, etc.). Only
            // shown when the build carries a maintainer public key.
            if BugReportEncryptor.isConfigured {
                Button {
                    saveEncryptedLog()
                } label: {
                    Label(L10n.diagSaveEncryptedLog, systemImage: "lock.doc.fill")
                }
                .buttonStyle(.bordered)
                .help(L10n.diagSaveEncryptedLogHelp)
            }

            // When the build carries a maintainer public key (release
            // build, or dev build with the env var passed through),
            // expose the encrypted-bundle path. The encrypted bundle
            // is opaque to GitHub's CDN
            // and to anyone but the maintainer, so a single button
            // routing to the public Issues form covers both general
            // bugs and security-class reports — the security split
            // only matters when the body is in cleartext, which is
            // never the case here.
            //
            // Dev / fork builds with no key fall back to the public-
            // tier-scrubbed paths so the report buttons aren't dead.
            if BugReportEncryptor.isConfigured {
                Button {
                    presentEncryptedReportPreview(target: .publicIssue)
                } label: {
                    Label(L10n.diagEncryptedReportBug, systemImage: "lock.doc")
                }
                .buttonStyle(.bordered)
                .help(L10n.diagEncryptedReportBugHelp)
            } else {
                Button {
                    reportOnGitHub()
                } label: {
                    Label(L10n.diagReportOnGitHub, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .help(L10n.diagReportOnGitHubHelp)

                Button {
                    reportPrivately()
                } label: {
                    Label(L10n.diagReportPrivately, systemImage: "lock.shield")
                }
                .buttonStyle(.bordered)
                .help(L10n.diagReportPrivatelyHelp)
            }

            Spacer()

            Button(role: .destructive) {
                clearAll()
            } label: {
                Label(L10n.diagClearAll, systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .disabled(entries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }


    // MARK: - Actions

    private func reload() {
        entries = DiagnosticsService.shared.recent(limit: 1000)
    }

    private func copyAll() {
        copyToClipboard(bundleText(for: filteredEntries))
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func copyRows(ids: Set<Int64>) {
        let rows = filteredEntries.filter { ids.contains($0.id) }
        copyToClipboard(bundleText(for: rows))
    }

    /// Copies the selected rows in their on-disk form — auth tokens are
    /// already substituted (the persistence-tier scrub runs at write
    /// time), but LAN IPs, file paths, RINCON IDs, and SMAPI account
    /// bindings are preserved. Useful when the user is debugging
    /// locally and needs the full context, OR when sharing privately
    /// with a maintainer over a trusted channel they've already vetted.
    /// Distinct from `copyRows` (which applies the export-tier scrub
    /// for public sharing).
    private func copyRowsWithPayload(ids: Set<Int64>) {
        let rows = filteredEntries.filter { ids.contains($0.id) }
        copyToClipboard(bundleTextWithPayload(for: rows))
    }

    private func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func formatRow(_ e: DiagnosticEntry) -> String {
        // Apply the export-tier scrub here, at the boundary where each
        // entry leaves the local store on its way into a clipboard,
        // file, or GitHub form. Entries on disk keep LAN IPs, paths,
        // and device IDs so the user's own diagnostic history stays
        // useful — the broader pass only runs when the row is about to
        // leave the user's machine.
        let safeMessage = DiagnosticsRedactor.scrubForPublicOutput(e.message)
        var s = "[\(Self.bundleStampFormatter.string(from: e.timestamp))] "
        s += "\(e.level.rawValue.uppercased())  \(e.tag)\n"
        s += "  \(safeMessage)"
        if let ctx = e.contextJSON, !ctx.isEmpty {
            let safeCtx = DiagnosticsRedactor.scrubForPublicOutput(ctx)
            s += "\n  context: \(safeCtx)"
        }
        return s
    }

    /// Same shape as `formatRow` but skips the export-tier scrub —
    /// shows the on-disk row exactly as stored. Auth tokens are still
    /// already substituted (the persistence-tier scrub ran at write
    /// time and never persists token values).
    private func formatRowWithPayload(_ e: DiagnosticEntry) -> String {
        var s = "[\(Self.bundleStampFormatter.string(from: e.timestamp))] "
        s += "\(e.level.rawValue.uppercased())  \(e.tag)\n"
        s += "  \(e.message)"
        if let ctx = e.contextJSON, !ctx.isEmpty {
            s += "\n  context: \(ctx)"
        }
        return s
    }

    /// Short app-version tag for filenames and prefilled text.
    /// Falls back to "unknown" if `CFBundleShortVersionString` is
    /// somehow absent. Sanitised to filename-safe characters
    /// (digits and dots only in practice; defensive trim anyway).
    private var versionTag: String {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return (raw?.trimmingCharacters(in: .whitespaces).filter {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-"
        }).flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
    }

    private func saveBundle() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let stamp = Self.fileNameFormatter.string(from: Date())
        panel.nameFieldStringValue = "choragus-diagnostics-v\(versionTag)-\(stamp).txt"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try bundleText(for: filteredEntries).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// Writes the encrypted diagnostic envelope to a user-chosen
    /// location via NSSavePanel. Same payload shape the
    /// "Report Bug (encrypted)" flow produces, minus the forced
    /// Downloads write and the GitHub form opener — for users who
    /// want to share the bundle out-of-band.
    private func saveEncryptedLog() {
        let rows = selection.isEmpty
            ? filteredEntries
            : filteredEntries.filter { selection.contains($0.id) }
        let rawPayload = rows.map { e in
            BugReportBundle.EntryPayload(
                timestamp: Self.bundleStampFormatter.string(from: e.timestamp),
                level: e.level.rawValue.uppercased(),
                tag: e.tag,
                message: e.message,
                context: e.contextJSON
            )
        }
        let payloadEntries = BugReportBundle.scrubForPublicOutput(rawPayload)
        let devicePayload = BugReportBundle.topologySnapshot(
            groups: sonosManager.groups,
            devices: sonosManager.devices,
            htSatChannelMaps: sonosManager.htSatChannelMaps,
            stereoChannelMaps: sonosManager.stereoChannelMaps
        )
        let envelope: Data
        do {
            envelope = try BugReportBundle.assemble(
                entries: payloadEntries,
                devices: devicePayload
            )
        } catch {
            encryptedReportError = error.localizedDescription
            return
        }

        let panel = NSSavePanel()
        // `.log` suffix matches the ReportBug flow so GitHub's
        // attachment uploader accepts the file on drag-drop without
        // a manual rename.
        let stamp = Self.fileNameFormatter.string(from: Date())
        panel.nameFieldStringValue = "Choragus-Bug-Bundle-v\(versionTag)-\(stamp).choragus-bundle.log"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try envelope.write(to: url, options: [.atomic])
            } catch {
                encryptedReportError = error.localizedDescription
            }
        }
    }

    private func clearAll() {
        DiagnosticsService.shared.clearAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { reload() }
    }

    /// Open the GitHub new-issue page with the diagnostic bundle
    /// pre-filled into the body. Uses the selected rows if any are
    /// highlighted, otherwise the full filtered set. If the resulting
    /// URL exceeds GitHub's effective limit (~7 KB), falls back to
    /// copying the bundle to the clipboard and opening the plain
    /// new-issue page so the user pastes manually.
    private func reportOnGitHub() {
        let rows = selection.isEmpty
            ? filteredEntries
            : filteredEntries.filter { selection.contains($0.id) }
        let bundle = bundleText(for: rows)

        let bodyTemplate = """
        **Choragus version:** \(versionTag)

        ## What happened?

        <!-- Describe what you were doing when this error occurred. -->

        ## Diagnostic info (auto-generated, redacted)

        ```
        \(bundle)
        ```
        """

        let baseURL = "https://github.com/scottwaters/Choragus/issues/new"
        var components = URLComponents(string: baseURL)!

        // GitHub silently truncates very long bodies and some browsers
        // refuse URLs over ~8 KB. Encode and check length first; if too
        // long, fall back to clipboard.
        let encodedBody = bodyTemplate.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlOK = encodedBody.count < 7000

        if urlOK {
            components.queryItems = [URLQueryItem(name: "body", value: bodyTemplate)]
            if let url = components.url {
                NSWorkspace.shared.open(url)
                return
            }
        }

        // Bundle too large for the URL — copy to clipboard, open the
        // plain issue page, surface a hint via the existing copied flag
        // so the user knows to paste.
        copyToClipboard(bundle)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        if let plainURL = URL(string: baseURL) {
            NSWorkspace.shared.open(plainURL)
        }
    }

    /// Builds the preview text + opens the consent sheet. The actual
    /// bundle write + encryption + Finder reveal + browser open all
    /// happen on user confirmation inside `previewSheet`.
    ///
    /// Preview uses `bundleText` (the public-output scrub) so the
    /// preview matches what `submitEncryptedReport` actually writes
    /// into the encrypted body. Earlier this used `bundleTextWithPayload`
    /// (no public scrub) while the bundle itself was also unscrubbed —
    /// the user saw an honest-but-leaky preview, and the bundle leaked
    /// `sn=`, LAN IPs, and home paths despite the bundle's
    /// "encrypted-to-the-maintainer" framing implying minimisation.
    /// Now both paths apply `scrubForPublicOutput`, and the redaction
    /// summary at the bottom of the preview reflects the actual on-wire
    /// content.
    private func presentEncryptedReportPreview(target: EncryptedReportTarget) {
        let rows = selection.isEmpty
            ? filteredEntries
            : filteredEntries.filter { selection.contains($0.id) }
        let preview = bundleText(for: rows)
        pendingEncryptedReport = PendingEncryptedReport(
            target: target,
            rows: rows,
            bundleText: preview
        )
    }

    /// Modal preview sheet shown before any bundle is written or any
    /// browser is opened. The user reviews exactly what will be in
    /// the encrypted body — every redaction marker visible — and
    /// either cancels or confirms.
    @ViewBuilder
    private func previewSheet(for pending: PendingEncryptedReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.diagPreviewTitle)
                .font(.headline)
            Text(L10n.diagPreviewSubtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Two-axis scroll. Long log lines stay on one line and
            // scroll horizontally; the whole bundle scrolls vertically.
            // `.fixedSize(horizontal: true, vertical: true)` stops
            // SwiftUI from compressing the Text width to fit the
            // container, which is what was producing the wordwrap.
            ScrollView([.horizontal, .vertical]) {
                Text(pending.bundleText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(8)
            }
            .frame(minHeight: 320)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            // Redaction summary — counts of substitution markers
            // present in the preview text. Lets the user confirm the
            // redactor actually fired and how often.
            let counts = redactionCounts(in: pending.bundleText)
            if counts.total > 0 {
                Text(L10n.diagPreviewRedactionFormat(counts.tokens, counts.lanIPs, counts.paths))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.diagPreviewRedactionNone)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(L10n.cancel) {
                    pendingEncryptedReport = nil
                }
                .keyboardShortcut(.cancelAction)
                Button(L10n.diagPreviewConfirm) {
                    submitEncryptedReport(pending)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 560)
    }

    /// Walks the preview text and counts substitution markers without
    /// regex — single pass, no allocations beyond the count.
    private func redactionCounts(in text: String) -> (tokens: Int, lanIPs: Int, paths: Int, total: Int) {
        let tokens = text.components(separatedBy: "<redacted>").count - 1
        let lanIPs = text.components(separatedBy: "<lan-ip>").count - 1
        // Home-path scrubber substitutes literal `~` for `/Users/...`
        // — count occurrences of `~/` as a proxy.
        let paths = text.components(separatedBy: "~/").count - 1
        return (tokens, lanIPs, paths, tokens + lanIPs + paths)
    }

    /// Runs after the user clicks "Encrypt and Open Form" in the
    /// preview sheet. Scrubs every payload string with
    /// `scrubForPublicOutput` (the export-tier pass), encrypts the
    /// scrubbed rows, writes the resulting envelope to ~/Downloads,
    /// reveals it in Finder, and opens the right destination form
    /// (public Issues or PVR).
    ///
    /// Scrubbing happens at the boundary where the row leaves the
    /// process — the same point as the clipboard / GitHub URL paths.
    /// Encryption to the maintainer's pubkey is defence-in-depth, not a
    /// substitute for minimisation: if the maintainer's private key is
    /// ever compromised or lost, every past bundle becomes readable, so
    /// the principle is to ship only what the maintainer needs to
    /// diagnose. `sid=` stays (identifies Spotify vs Apple Music etc.);
    /// `sn=` (account binding) is removed; LAN IPs collapse to
    /// `<lan-ip>`; home paths collapse to `~/`; RINCON device IDs keep
    /// last 4 chars for cross-event correlation.
    private func submitEncryptedReport(_ pending: PendingEncryptedReport) {
        pendingEncryptedReport = nil

        let rawPayload = pending.rows.map { e in
            BugReportBundle.EntryPayload(
                timestamp: Self.bundleStampFormatter.string(from: e.timestamp),
                level: e.level.rawValue.uppercased(),
                tag: e.tag,
                message: e.message,
                context: e.contextJSON
            )
        }
        let payloadEntries = BugReportBundle.scrubForPublicOutput(rawPayload)
        let devicePayload = BugReportBundle.topologySnapshot(
            groups: sonosManager.groups,
            devices: sonosManager.devices,
            htSatChannelMaps: sonosManager.htSatChannelMaps,
            stereoChannelMaps: sonosManager.stereoChannelMaps
        )

        let envelope: Data
        do {
            envelope = try BugReportBundle.assemble(
                entries: payloadEntries,
                devices: devicePayload
            )
        } catch {
            encryptedReportError = error.localizedDescription
            return
        }

        // Land the file in ~/Downloads so it's where Finder reveals
        // and where the user expects "I just saved a thing".
        //
        // The trailing `.log` suffix is here so GitHub's attachment
        // uploader accepts the file on drag-drop without a manual
        // rename — the underlying contents are still the
        // `ChoragusBugBundle` JSON envelope, and the maintainer-side
        // decrypter doesn't care about the filename. Issue #19's
        // reporter discovered this workaround themselves and noted
        // it ("I added a `.log` extension so I could upload it
        // here") — baking it in removes the friction. The double
        // extension also signals to the user that the file is opaque
        // / app-specific even though it's named like a log.
        let stamp = Self.fileNameFormatter.string(from: Date())
        let filename = "Choragus-Bug-Bundle-v\(versionTag)-\(stamp).choragus-bundle.log"
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard let target = downloads?.appendingPathComponent(filename) else {
            encryptedReportError = "Could not locate Downloads folder."
            return
        }

        do {
            try envelope.write(to: target, options: [.atomic])
        } catch {
            encryptedReportError = error.localizedDescription
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([target])

        let formURL = buildPrefilledFormURL(target: pending.target, bundleFilename: filename)
        if let formURL {
            NSWorkspace.shared.open(formURL)
        }
    }

    /// Builds the destination URL with title + body pre-filled to
    /// remind the user (a) the bundle was just saved to Downloads with
    /// this exact filename, and (b) to drag it into the comment.
    /// GitHub's public Issues form supports `?title=...&body=...`
    /// query params; the PVR new-advisory form does not, so the
    /// pre-fill is best-effort there — when ignored the form opens
    /// blank and the Finder reveal of the named bundle file remains
    /// the primary affordance.
    private func buildPrefilledFormURL(target: EncryptedReportTarget,
                                       bundleFilename: String) -> URL? {
        let body = L10n.diagEncryptedReportFormBody(bundleFilename)

        let baseURL: String
        switch target {
        case .publicIssue:
            baseURL = "https://github.com/scottwaters/Choragus/issues/new"
        case .privateAdvisory:
            baseURL = "https://github.com/scottwaters/Choragus/security/advisories/new"
        }

        guard var components = URLComponents(string: baseURL) else { return nil }
        // Title intentionally NOT pre-filled — reporters were leaving
        // the canned default in place, producing dozens of issues with
        // identical generic titles. A blank title field forces the
        // user to write something specific to their problem.
        components.queryItems = [
            URLQueryItem(name: "body", value: body),
        ]
        // GitHub silently truncates very long URL query bodies and
        // some browsers refuse URLs over ~8 KB. The body here is a
        // short fixed template — well under the limit — but check
        // anyway in case future template growth or filename length
        // pushes us over, and degrade to a bare URL if it does.
        if let url = components.url, url.absoluteString.count < 7000 {
            return url
        }
        return URL(string: baseURL)
    }

    /// Opens the repository's GitHub Security Advisory form so the
    /// user can file the same bundle as a non-public report instead of
    /// a public issue. GitHub's advisory form does not accept a body
    /// query parameter, so the bundle is copied to the clipboard and
    /// the user pastes it into the Description field.
    private func reportPrivately() {
        let rows = selection.isEmpty
            ? filteredEntries
            : filteredEntries.filter { selection.contains($0.id) }
        let bundle = bundleText(for: rows)

        copyToClipboard(bundle)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }

        if let url = URL(string: "https://github.com/scottwaters/Choragus/security/advisories/new") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Plain-text bundle for the user to paste into a GitHub issue.
    /// Already redacted at log time, so safe to share verbatim. Used
    /// for both Copy All and right-click Copy Row(s) — single shape so
    /// the maintainer always sees the version + macOS context regardless
    /// of which copy path the reporter used.
    private func bundleText(for selected: [DiagnosticEntry]) -> String {
        var out = "=== Choragus Diagnostics Bundle ===\n"
        out += "Generated: \(Self.bundleStampFormatter.string(from: Date()))\n"
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            out += "Choragus version: \(v)\n"
        }
        out += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "Bundle ID: \(Bundle.main.bundleIdentifier ?? "<unknown>")\n"
        out += "\n=== Events (\(selected.count) of \(entries.count) total) ===\n"
        for e in selected {
            out += formatRow(e) + "\n"
        }
        return out
    }

    /// Same header as `bundleText`, but rows are formatted via
    /// `formatRowWithPayload` so LAN IPs, paths, device IDs etc. are
    /// preserved. For the user's own local copying — not for sharing
    /// without an additional consent step.
    private func bundleTextWithPayload(for selected: [DiagnosticEntry]) -> String {
        var out = "=== Choragus Diagnostics Bundle (with payload — for local use) ===\n"
        out += "Generated: \(Self.bundleStampFormatter.string(from: Date()))\n"
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            out += "Choragus version: \(v)\n"
        }
        out += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        out += "Bundle ID: \(Bundle.main.bundleIdentifier ?? "<unknown>")\n"
        out += "\n=== Events (\(selected.count) of \(entries.count) total) ===\n"
        for e in selected {
            out += formatRowWithPayload(e) + "\n"
        }
        return out
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let bundleStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    private static let fileNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()
}

