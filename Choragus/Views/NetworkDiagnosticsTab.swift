/// Diagnostics → Network tab: the single consolidated view of speaker
/// and network diagnostics, read live from each speaker's own `:1400`
/// endpoints. One row per speaker (or per room when grouped) carrying
/// a plain-language status word, connection band + channel, HTTP
/// round-trip latency with history sparkline, interference counter,
/// firmware (marketing + internal build), serial, and IP.
///
/// Sort: click any column header. Group: "Group by room" toggle folds
/// stereo pairs / home-theater satellites into one row per room
/// showing the worst member's status and latency. Filter: text field
/// matches room, model, or IP. Health-check summary rows at the foot
/// answer the reachability / band / latency questions first.
import SwiftUI
import SonosKit

@MainActor
final class NetworkDiagnosticsModel: ObservableObject {
    @Published var rows: [SpeakerNetworkDiagnostics] = []
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    /// Rolling RTT history per device for the sparkline; capped so the
    /// buffer stays bounded across long sessions.
    @Published var rttHistory: [String: [Double]] = [:]

    static let historyLimit = 40
    static let refreshInterval: Duration = .seconds(30)

    private let service = SpeakerNetworkDiagnosticsService()
    private var autoRefreshTask: Task<Void, Never>?
    private var lastDeviceSource: () -> [SonosDevice] = { [] }

    /// Visible physical speakers — `_MR` media-renderer shadow records
    /// excluded. Captured as a closure so the auto-refresh loop always
    /// reads the current device set.
    func deviceSource(from manager: SonosManager) -> () -> [SonosDevice] {
        { [weak manager] in
            guard let manager else { return [] }
            return manager.devices.values.filter { !$0.id.hasSuffix("_MR") }
        }
    }

    func startAutoRefresh(devices: @escaping () -> [SonosDevice]) {
        lastDeviceSource = devices
        stopAutoRefresh()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(devices: devices())
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    func refreshFromLastSource() async {
        await refresh(devices: lastDeviceSource())
    }

    func refresh(devices: [SonosDevice]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let fetched = await service.fetchAll(devices: devices)
        rows = fetched.sorted {
            $0.roomName.localizedCaseInsensitiveCompare($1.roomName) == .orderedAscending
        }
        for row in fetched {
            var history = rttHistory[row.deviceID] ?? []
            history.append(row.httpRTTMillis ?? -1)   // -1 marks an unreachable sample
            if history.count > Self.historyLimit {
                history.removeFirst(history.count - Self.historyLimit)
            }
            rttHistory[row.deviceID] = history
        }
        lastUpdated = Date()
    }
}

/// Presentation row: either one speaker, or one room aggregating its
/// bonded members (grouped mode). Flat value type so `Table` sorting
/// via `KeyPathComparator` works uniformly in both modes.
struct SpeakerDisplayRow: Identifiable {
    let id: String
    let name: String
    let model: String
    let ip: String
    let bandText: String
    let bandTint: Color
    let bandIsWired: Bool
    let sortBand: Int
    let latencyText: String
    let latencyTint: Color
    let sortRTT: Double
    let interferenceText: String
    let interferenceTint: Color
    let sortInterference: Int
    let firmware: String
    let serial: String
    let statusRank: Int
    /// Device whose RTT history drives the sparkline (worst member in
    /// grouped mode).
    let sparklineDeviceID: String
    /// False when the measured unit is unreachable — the latency cell
    /// then shows a placeholder instead of a value (the Status column
    /// already carries "Offline").
    let showsLatency: Bool
    /// Member rows when this row is a room heading (grouped mode);
    /// `nil` for individual speakers so the table shows no disclosure.
    var children: [SpeakerDisplayRow]?

    init(single diag: SpeakerNetworkDiagnostics) {
        id = diag.deviceID
        name = diag.displayName
        model = diag.modelName
        ip = diag.ip
        bandText = diag.bandText
        bandTint = diag.bandTint
        bandIsWired = diag.band == .wired
        sortBand = diag.sortBand
        latencyText = diag.latencyText
        latencyTint = diag.latencyTint
        sortRTT = diag.httpRTTMillis ?? .greatestFiniteMagnitude
        interferenceText = diag.interferenceText
        interferenceTint = diag.interferenceTint
        sortInterference = diag.phyErrors ?? -1
        firmware = diag.firmwareText
        serial = diag.serialNumber ?? "—"
        statusRank = diag.statusRank
        sparklineDeviceID = diag.deviceID
        showsLatency = diag.reachable
        children = nil
    }

    /// Room aggregate: identity fields come from the primary member
    /// (shortest zone name — the unsuffixed unit); status, latency and
    /// interference come from the worst member, because the room
    /// misbehaves whenever any bonded member does.
    init(room: String, members: [SpeakerNetworkDiagnostics]) {
        let primary = members.min { $0.displayName.count < $1.displayName.count } ?? members[0]
        let worstStatus = members.map(\.statusRank).max() ?? 0
        let worstRTTMember = members.max {
            ($0.httpRTTMillis ?? .greatestFiniteMagnitude) < ($1.httpRTTMillis ?? .greatestFiniteMagnitude)
        } ?? primary
        let worstInterference = members.max { ($0.phyErrors ?? -1) < ($1.phyErrors ?? -1) } ?? primary

        id = "room:\(room)"
        name = members.count > 1 ? "\(room) (\(members.count))" : primary.displayName
        model = Set(members.map(\.modelName)).count == 1
            ? primary.modelName
            : members.map(\.modelName).sorted().joined(separator: " + ")
        ip = primary.ip
        bandText = primary.bandText
        bandTint = primary.bandTint
        bandIsWired = primary.band == .wired
        sortBand = primary.sortBand
        latencyText = worstRTTMember.latencyText
        latencyTint = worstRTTMember.latencyTint
        sortRTT = worstRTTMember.httpRTTMillis ?? .greatestFiniteMagnitude
        interferenceText = worstInterference.interferenceText
        interferenceTint = worstInterference.interferenceTint
        sortInterference = worstInterference.phyErrors ?? -1
        firmware = primary.firmwareText
        serial = members.count > 1 ? "—" : (primary.serialNumber ?? "—")
        statusRank = worstStatus
        sparklineDeviceID = worstRTTMember.deviceID
        showsLatency = worstRTTMember.reachable
        // Rooms with bonded members expand to one row per unit; a
        // single-speaker room is a leaf.
        children = members.count > 1
            ? members
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                .map { SpeakerDisplayRow(single: $0) }
            : nil
    }
}

struct NetworkDiagnosticsTab: View {
    @EnvironmentObject var sonosManager: SonosManager
    @ObservedObject var model: NetworkDiagnosticsModel
    @State private var copied = false
    @State private var filter = ""
    @State private var groupByRoom = true
    @State private var sortOrder = [KeyPathComparator(\SpeakerDisplayRow.statusRank, order: .reverse)]

    private var rows: [SpeakerDisplayRow] {
        let filtered = model.rows.filter {
            filter.isEmpty
                || $0.displayName.localizedCaseInsensitiveContains(filter)
                || $0.modelName.localizedCaseInsensitiveContains(filter)
                || $0.ip.contains(filter)
        }
        let display: [SpeakerDisplayRow]
        if groupByRoom {
            let byRoom = Dictionary(grouping: filtered) { $0.roomName.isEmpty ? $0.deviceID : $0.roomName }
            display = byRoom.map { SpeakerDisplayRow(room: $0.key, members: $0.value) }
        } else {
            display = filtered.map { SpeakerDisplayRow(single: $0) }
        }
        return display.sorted(using: sortOrder)
    }

    @State private var showInfo = false

    var body: some View {
        VStack(spacing: 0) {
            statTiles
            // Counters are cumulative per speaker, so the first sample
            // after opening the tab reads as a huge number until repeat
            // samples give it a baseline to diff against. Say so rather
            // than let the numbers look like a fault.
            Text(L10n.diagNetworkSettleNote)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            toolbar
            Divider()
            table
            Divider()
            footer
        }
        .onAppear { model.startAutoRefresh(devices: model.deviceSource(from: sonosManager)) }
        .onDisappear { model.stopAutoRefresh() }
    }

    // MARK: - Stat tiles

    private var statTiles: some View {
        let total = model.rows.count
        let reachable = model.rows.filter(\.reachable).count
        let alerts = model.rows.filter { $0.statusRank > 0 }.count
        let on5 = model.rows.filter { $0.band == .ghz5 || $0.band == .wired || $0.band == .homeTheater }.count
        let rtts = model.rows.compactMap(\.httpRTTMillis).sorted()
        let median = rtts.isEmpty ? nil : rtts[rtts.count / 2]
        return HStack(spacing: 10) {
            statTile(icon: "antenna.radiowaves.left.and.right",
                     tint: reachable == total ? .green : .red,
                     value: "\(reachable)/\(total)",
                     label: L10n.diagTileOnline)
            statTile(icon: "wifi",
                     tint: on5 == total ? .green : .secondary,
                     value: "\(on5)/\(total)",
                     label: L10n.diagTileGoodLink)
            statTile(icon: alerts == 0 ? "checkmark.circle" : "exclamationmark.triangle",
                     tint: alerts == 0 ? .green : .orange,
                     value: "\(alerts)",
                     label: L10n.diagTileAlerts)
            statTile(icon: "gauge.with.needle",
                     tint: (median ?? 0) < 50 ? .green : ((median ?? 0) < 150 ? .orange : .red),
                     value: median.map { String(format: "%.0f ms", $0) } ?? "—",
                     label: L10n.diagTileMedianLatency)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func statTile(icon: String, tint: Color, value: String, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.diagFilterRooms, text: $filter)
                    .textFieldStyle(.plain)
                    .font(.callout)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
            .frame(width: 200)

            Toggle(L10n.diagGroupByRoom, isOn: $groupByRoom)
                .toggleStyle(.checkbox)
                .font(.caption)

            Spacer()

            if let updated = model.lastUpdated {
                Text(L10n.diagNetworkUpdatedFormat(Self.timeFormatter.string(from: updated)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.refreshFromLastSource() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help(L10n.refresh)
            }
            Button {
                showInfo.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showInfo, arrowEdge: .bottom) {
                Text(L10n.diagHealthBanner)
                    .font(.callout)
                    .frame(width: 300)
                    .padding(14)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var table: some View {
        Table(rows, children: \.children, sortOrder: $sortOrder) {
            TableColumn(L10n.diagColumnStatus, value: \.statusRank) { row in
                statusPill(row.statusRank)
            }
            .width(min: 95, ideal: 115)

            TableColumn(L10n.roomLabel, value: \.name) { row in
                Text(row.name).font(.callout.weight(.medium))
            }
            .width(min: 110, ideal: 145)

            TableColumn(L10n.diagSpeakerColumnModel, value: \.model) { row in
                Text(row.model).font(.callout).lineLimit(1)
            }
            .width(min: 90, ideal: 120)

            TableColumn(L10n.diagSpeakerColumnIP, value: \.ip) { row in
                Text(row.ip).font(.callout.monospaced()).textSelection(.enabled)
            }
            .width(min: 90, ideal: 105)

            TableColumn(L10n.diagNetworkColumnConnection, value: \.sortBand) { row in
                HStack(spacing: 4) {
                    Image(systemName: row.bandIsWired ? "cable.connector" : "wifi")
                        .font(.caption2)
                    Text(row.bandText).font(.caption.weight(.medium)).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(row.bandTint.opacity(0.13)))
                .foregroundStyle(row.bandTint == .secondary ? Color.secondary : row.bandTint)
            }
            .width(min: 120, ideal: 150)

            TableColumn(L10n.diagNetworkColumnLatency, value: \.sortRTT) { row in
                if row.showsLatency {
                    HStack(spacing: 6) {
                        Circle().fill(row.latencyTint).frame(width: 6, height: 6)
                        Text(row.latencyText)
                            .font(.callout.monospacedDigit())
                            .frame(minWidth: 44, alignment: .leading)
                        sparkline(for: row.sparklineDeviceID)
                    }
                } else {
                    Text("—")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
            .width(min: 115, ideal: 145)

            TableColumn(L10n.diagColumnInterference, value: \.sortInterference) { row in
                Text(row.interferenceText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(row.interferenceTint)
            }
            .width(min: 75, ideal: 90)

            TableColumn(L10n.diagSpeakerColumnFirmware, value: \.firmware) { row in
                Text(row.firmware).font(.callout.monospaced()).lineLimit(1)
            }
            .width(min: 90, ideal: 125)

            TableColumn(L10n.diagColumnSerial, value: \.serial) { row in
                Text(row.serial).font(.callout.monospaced()).textSelection(.enabled)
            }
            .width(min: 100, ideal: 135)
        }
    }

    private func statusPill(_ rank: Int) -> some View {
        let tint = SpeakerStatusDisplay.tint(forRank: rank)
        let icon = rank == 0 ? "checkmark.circle.fill"
            : rank == 1 ? "exclamationmark.triangle.fill"
            : "xmark.circle.fill"
        return HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(SpeakerStatusDisplay.text(forRank: rank))
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.13)))
        .foregroundStyle(tint)
    }

    /// Bar sparkline over the rolling RTT history. Height is scaled
    /// against a 300 ms ceiling so a quiet fleet reads as uniformly
    /// short bars; unreachable samples render full-height red.
    private func sparkline(for deviceID: String) -> some View {
        let history = model.rttHistory[deviceID] ?? []
        let ceiling = 300.0
        return HStack(alignment: .bottom, spacing: 1) {
            ForEach(Array(history.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(sample < 0 ? Color.red : sampleTint(sample))
                    .frame(width: 2, height: sample < 0 ? 14 : max(2, min(sample / ceiling, 1) * 14))
            }
        }
        .frame(height: 14, alignment: .bottom)
    }

    private func sampleTint(_ rtt: Double) -> Color {
        if rtt < 50 { return .green }
        if rtt < 150 { return .orange }
        return .red
    }

    // MARK: - Footer / copy

    private var footer: some View {
        HStack {
            Button {
                copyReport()
            } label: {
                Label(copied ? L10n.copied : L10n.diagCopyAll,
                      systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .disabled(model.rows.isEmpty)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Cleartext, unredacted — LAN IPs and serials are the content
    /// here, same policy as the Speakers tab copy action. Always
    /// per-speaker (ungrouped) so nothing is lost in aggregation.
    private func copyReport() {
        var lines: [String] = ["=== Choragus Speaker Network ==="]
        for row in model.rows {
            lines.append(row.displayName)
            lines.append("  Model: \(row.modelName)  IP: \(row.ip)")
            lines.append("  Connection: \(row.bandText)")
            lines.append("  RTT: \(row.latencyText)")
            if let noise = row.noiseFloorDBm { lines.append("  Noise floor: \(noise) dBm") }
            if let phy = row.phyErrors { lines.append("  PHY errors: \(phy)") }
            lines.append("  Firmware: \(row.firmwareText)")
            if let hardware = row.hardwareVersion { lines.append("  Hardware: \(hardware)") }
            if let serial = row.serialNumber { lines.append("  Serial: \(serial)") }
            if let date = row.softwareDate { lines.append("  Firmware date: \(date)") }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
