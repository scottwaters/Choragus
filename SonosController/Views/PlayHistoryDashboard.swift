/// PlayHistoryDashboard.swift — Visually rich listening stats dashboard.
import SwiftUI
import Charts
import SonosKit

// MARK: - Chart Color Themes

enum ChartTheme: String, CaseIterable, Identifiable {
    case ocean = "Ocean"
    case sunset = "Sunset"
    case neon = "Neon"
    case forest = "Forest"
    case berry = "Berry"
    case mono = "Mono"

    var id: String { rawValue }

    var primary: Color {
        switch self {
        case .ocean: return .blue
        case .sunset: return .orange
        case .neon: return .cyan
        case .forest: return .green
        case .berry: return .purple
        case .mono: return .primary
        }
    }

    var secondary: Color {
        switch self {
        case .ocean: return .purple
        case .sunset: return .red
        case .neon: return .pink
        case .forest: return .teal
        case .berry: return .pink
        case .mono: return .gray
        }
    }

    var barGradient: LinearGradient {
        LinearGradient(colors: [primary, secondary], startPoint: .bottom, endPoint: .top)
    }

    var horizontalGradient: LinearGradient {
        LinearGradient(colors: [primary, secondary], startPoint: .leading, endPoint: .trailing)
    }

    var areaGradient: LinearGradient {
        LinearGradient(colors: [secondary.opacity(0.3), secondary.opacity(0.05)],
                       startPoint: .top, endPoint: .bottom)
    }

    var cardGradient: LinearGradient {
        LinearGradient(colors: [primary.opacity(0.12), secondary.opacity(0.12)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var swatchColors: [Color] { [primary, secondary] }
}

// MARK: - Dashboard

struct PlayHistoryDashboard: View {
    @EnvironmentObject var historyManager: PlayHistoryManager
    let entries: [PlayHistoryEntry]
    @Binding var expandedArtEntry: PlayHistoryEntry?

    // Cached stats — computed once, updated only when entries change
    @State private var stats: DashboardStats?

    // Animated counter states
    @State private var animatedPlays: Double = 0
    @State private var animatedHours: Double = 0
    @State private var animatedArtists: Double = 0
    @State private var animatedRooms: Double = 0
    @State private var appeared = false

    @AppStorage(UDKey.chartTheme) private var selectedTheme: String = ChartTheme.ocean.rawValue
    @AppStorage(UDKey.customPrimaryColor) private var customPrimaryHex: String = "#3B82F6"
    @AppStorage(UDKey.customSecondaryColor) private var customSecondaryHex: String = "#8B5CF6"
    @State private var showCustomEditor = false
    @State private var hoveredDay: Date?
    @State private var hoveredHour: Int?
    @State private var isRefreshingStats = false

    private var theme: ChartTheme {
        ChartTheme(rawValue: selectedTheme) ?? .ocean
    }

    private var isCustomTheme: Bool { selectedTheme == "Custom" }

    private var effectivePrimary: Color {
        isCustomTheme ? Color(hex: customPrimaryHex) : theme.primary
    }
    private var effectiveSecondary: Color {
        isCustomTheme ? Color(hex: customSecondaryHex) : theme.secondary
    }
    private var effectiveBarGradient: LinearGradient {
        let p = effectivePrimary, s = effectiveSecondary
        return LinearGradient(colors: [p, s], startPoint: .bottom, endPoint: .top)
    }
    private var effectiveHorizontalGradient: LinearGradient {
        let p = effectivePrimary, s = effectiveSecondary
        return LinearGradient(colors: [p, s], startPoint: .leading, endPoint: .trailing)
    }
    private var effectiveAreaGradient: LinearGradient {
        let s = effectiveSecondary
        return LinearGradient(colors: [s.opacity(0.3), s.opacity(0.05)],
                       startPoint: .top, endPoint: .bottom)
    }
    private var effectiveCardGradient: LinearGradient {
        let p = effectivePrimary, s = effectiveSecondary
        return LinearGradient(colors: [p.opacity(0.12), s.opacity(0.12)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    // MARK: - Stats Accessors (from cached @State, zero cost per access)

    private var totalEntries: Int { stats?.totalEntries ?? 0 }
    private var totalListeningHours: Double { stats?.totalListeningHours ?? 0 }
    private var uniqueArtistCount: Int { stats?.uniqueArtistCount ?? 0 }
    private var uniqueRoomCount: Int { stats?.uniqueRoomCount ?? 0 }
    private var uniqueAlbumCount: Int { stats?.uniqueAlbumCount ?? 0 }
    private var uniqueStationCount: Int { stats?.uniqueStationCount ?? 0 }
    private var dailyActivity: [(Date, Int)] { stats?.dailyActivity ?? [] }
    private var hourlyDistribution: [(Int, Int)] { stats?.hourlyDistribution ?? [] }
    private var peakHour: Int { stats?.peakHour ?? 12 }
    private var mostPlayedArtists: [(String, Int)] { stats?.mostPlayedArtists ?? [] }
    private var mostPlayedTracks: [(String, String, Int)] { stats?.mostPlayedTracks ?? [] }
    private var mostPlayedStations: [(String, Int)] { stats?.mostPlayedStations ?? [] }
    private var mostPlayedAlbums: [(String, Int)] { stats?.mostPlayedAlbums ?? [] }
    private var sourceDistribution: [(String, Int)] { stats?.sourceDistribution ?? [] }
    private var dayOfWeekDistribution: [(String, Int)] { stats?.dayOfWeekDistribution ?? [] }
    private var roomDistribution: [(String, Int)] { stats?.roomDistribution ?? [] }
    private var listeningStreak: Int { stats?.listeningStreak ?? 0 }
    private var currentStreak: Int { stats?.currentStreak ?? 0 }
    private var averagePlaysPerDay: Double { stats?.averagePlaysPerDay ?? 0 }
    private var starredCount: Int { stats?.starredCount ?? 0 }

    private func recomputeStats() {
        stats = DashboardStats(entries: entries, historyManager: historyManager)
    }

    private func refreshStatsAsync() {
        isRefreshingStats = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            historyManager.refreshDailySummary()
            recomputeStats()
            isRefreshingStats = false
        }
    }

    // MARK: - Body

    var body: some View {
        if entries.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 20) {
                    themePicker
                    heroStats
                    quickStatsPills
                    activityChart
                    HStack(alignment: .top, spacing: 16) {
                        peakHoursChart
                        dayOfWeekChart
                    }
                    HStack(alignment: .top, spacing: 16) {
                        topArtistsChart
                        topSourcesChart
                    }
                    HStack(alignment: .top, spacing: 16) {
                        topTracksChart
                        topStationsChart
                    }
                    if !mostPlayedAlbums.isEmpty {
                        topAlbumsChart
                    }
                    if roomDistribution.count > 1 {
                        roomChart
                    }
                    recentTimeline
                }
                .padding(20)
            }
            .onAppear {
                recomputeStats()
                animateCounters()
            }
            .onChange(of: entries.count) {
                recomputeStats()
                animateToCurrentValues()
            }
        }
    }

    // MARK: - Theme Picker

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Theme")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer()

                if UserDefaults.standard.bool(forKey: UDKey.realtimeStats) {
                    if isRefreshingStats {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Updating...")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            refreshStatsAsync()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10))
                                Text("Refresh Stats")
                                    .font(.system(size: 10))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh daily summary and recalculate stats")
                    }

                    if let lastRollup = historyManager.lastRollupDate {
                        Text(lastRollup.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                ForEach(ChartTheme.allCases) { t in
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            selectedTheme = t.rawValue
                            showCustomEditor = false
                            NSColorPanel.shared.close()
                        }
                    } label: {
                        HStack(spacing: 0) {
                            ForEach(Array(t.swatchColors.enumerated()), id: \.offset) { _, color in
                                color.frame(width: 10, height: 20)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(t.rawValue == selectedTheme ? Color.primary : Color.clear, lineWidth: 2)
                        )
                        .shadow(color: t.rawValue == selectedTheme ? .primary.opacity(0.2) : .clear, radius: 2)
                    }
                    .buttonStyle(.plain)
                    .help(t.rawValue)
                }

                Divider()
                    .frame(height: 16)

                // Custom theme button
                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        selectedTheme = "Custom"
                        showCustomEditor.toggle()
                        if !showCustomEditor { NSColorPanel.shared.close() }
                    }
                } label: {
                    HStack(spacing: 4) {
                        HStack(spacing: 0) {
                            Color(hex: customPrimaryHex).frame(width: 14, height: 20)
                            Color(hex: customSecondaryHex).frame(width: 14, height: 20)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(isCustomTheme ? Color.primary : Color.clear, lineWidth: 2)
                        )
                        Image(systemName: "paintpalette")
                            .font(.system(size: 10))
                            .foregroundStyle(isCustomTheme ? .primary : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .help("Custom Theme Editor")

                Spacer()
            }

            // Custom color editor
            if showCustomEditor && isCustomTheme {
                HStack(spacing: 16) {
                    colorPickerItem("Primary", hex: $customPrimaryHex)
                    colorPickerItem("Secondary", hex: $customSecondaryHex)
                    Spacer()
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func colorPickerItem(_ label: String, hex: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            ColorPicker("", selection: Binding(
                get: { Color(hex: hex.wrappedValue) },
                set: { hex.wrappedValue = $0.toHex() }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 30)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("No listening data yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Play some music and your stats will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Hero Stats

    private var heroStats: some View {
        HStack(spacing: 16) {
            statCard(icon: "play.circle.fill", value: animatedPlays, label: "Total Plays", format: { "\(Int($0))" })
            statCard(icon: "clock.fill", value: animatedHours, label: "Hours Listened", format: { String(format: "%.1fh", $0) })
            statCard(icon: "person.2.fill", value: animatedArtists, label: "Artists", format: { "\(Int($0))" })
            statCard(icon: "hifispeaker.2.fill", value: animatedRooms, label: "Rooms", format: { "\(Int($0))" })
        }
    }

    private func statCard(icon: String, value: Double, label: String, format: (Double) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(effectivePrimary)
            Text(format(value))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(effectiveCardGradient)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func animateCounters() {
        guard !appeared else { return }
        appeared = true
        withAnimation(.easeOut(duration: 0.8)) {
            animatedPlays = Double(totalEntries)
            animatedHours = totalListeningHours
            animatedArtists = Double(uniqueArtistCount)
            animatedRooms = Double(uniqueRoomCount)
        }
    }

    private func animateToCurrentValues() {
        withAnimation(.easeOut(duration: 0.4)) {
            animatedPlays = Double(totalEntries)
            animatedHours = totalListeningHours
            animatedArtists = Double(uniqueArtistCount)
            animatedRooms = Double(uniqueRoomCount)
        }
    }

    // MARK: - Listening Activity (Last 30 Days)

    private var activityChart: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                let data = dailyActivity
                let avg = data.map(\.1).reduce(0, +) / max(data.count, 1)

                HStack {
                    Text("Listening Activity")
                        .font(.headline)
                    Spacer()
                    if let hDay = hoveredDay,
                       let match = data.first(where: { Calendar.current.isDate($0.0, inSameDayAs: hDay) }) {
                        Text("\(match.1) plays")
                            .font(.system(size: 12, weight: .semibold))
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(match.0, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Last 30 days · avg: \(avg)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Chart {
                    ForEach(data, id: \.0) { day, count in
                        BarMark(
                            x: .value("Day", day, unit: .day),
                            y: .value("Plays", count)
                        )
                        .foregroundStyle(effectiveBarGradient)
                        .cornerRadius(3)
                        .opacity(hoveredDay == nil || Calendar.current.isDate(day, inSameDayAs: hoveredDay!) ? 1 : 0.4)
                    }
                    RuleMark(y: .value("Average", avg))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(.secondary.opacity(0.5))
                }
                .chartXSelection(value: $hoveredDay)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        AxisGridLine()
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.quaternary)
                    }
                }
                .frame(height: 180)
            }
        }
    }

    // MARK: - Peak Hours

    private var peakHoursChart: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                let data = hourlyDistribution

                HStack {
                    Text("Peak Listening Hours")
                        .font(.headline)
                    Spacer()
                    if let hHour = hoveredHour, let match = data.first(where: { $0.0 == hHour }) {
                        Text("\(match.1) plays")
                            .font(.system(size: 12, weight: .semibold))
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(formatHour(hHour))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Peak: \(formatHour(peakHour))")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(effectiveSecondary, in: Capsule())
                    }
                }

                Chart {
                    ForEach(data, id: \.0) { hour, count in
                        AreaMark(
                            x: .value("Hour", hour),
                            y: .value("Plays", count)
                        )
                        .foregroundStyle(effectiveAreaGradient)
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Hour", hour),
                            y: .value("Plays", count)
                        )
                        .foregroundStyle(effectiveSecondary)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }

                    let pk = peakHour
                    let pkCount = data.first(where: { $0.0 == pk })?.1 ?? 0
                    PointMark(x: .value("Hour", pk), y: .value("Plays", pkCount))
                        .foregroundStyle(effectiveSecondary)
                        .symbolSize(hoveredHour == pk ? 80 : 60)

                    if let hHour = hoveredHour, hHour != pk, let match = data.first(where: { $0.0 == hHour }) {
                        PointMark(x: .value("Hour", hHour), y: .value("Plays", match.1))
                            .foregroundStyle(effectivePrimary)
                            .symbolSize(50)
                    }
                }
                .chartXSelection(value: $hoveredHour)
                .chartXAxis {
                    AxisMarks(values: .stride(by: 3)) { value in
                        if let hour = value.as(Int.self) {
                            AxisValueLabel { Text(formatHour(hour)).font(.caption2) }
                        }
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(.quaternary)
                    }
                }
                .chartXScale(domain: 0...23)
                .frame(height: 150)
            }
        }
    }

    // MARK: - Top Artists

    private var topArtistsChart: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Top Artists", systemImage: "music.mic")
                    .font(.headline)

                let artists = mostPlayedArtists.prefix(8)
                if artists.isEmpty {
                    Text("No data").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Chart {
                        ForEach(Array(artists.enumerated()), id: \.offset) { _, item in
                            BarMark(
                                x: .value("Plays", item.1),
                                y: .value("Artist", item.0)
                            )
                            .foregroundStyle(effectiveHorizontalGradient)
                            .cornerRadius(4)
                            .annotation(position: .trailing, spacing: 4) {
                                Text("\(item.1)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                                .font(.caption)
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(artists.count) * 32)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Top Sources Donut

    private var topSourcesChart: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Top Sources", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)

                let sources = Array(sourceDistribution.prefix(8))
                if sources.isEmpty {
                    Text("No data").font(.caption).foregroundStyle(.tertiary)
                } else {
                    ZStack {
                        Chart {
                            ForEach(sources, id: \.0) { name, count in
                                SectorMark(
                                    angle: .value("Plays", count),
                                    innerRadius: .ratio(0.55),
                                    angularInset: 1.5
                                )
                                .foregroundStyle(ServiceColor.color(for: name))
                                .cornerRadius(4)
                            }
                        }
                        .frame(width: 180, height: 180)

                        VStack(spacing: 2) {
                            Text("\(totalEntries)")
                                .font(.title3)
                                .fontWeight(.bold)
                            Text("tracks")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                        ForEach(sources, id: \.0) { name, count in
                            HStack(spacing: 4) {
                                Circle().fill(ServiceColor.color(for: name)).frame(width: 8, height: 8)
                                Text(name).font(.caption2).lineLimit(1)
                                Spacer()
                                Text("\(count)").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Recent Timeline

    private var recentTimeline: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Recent Activity", systemImage: "clock.arrow.circlepath")
                    .font(.headline)

                let recent = historyManager.recentlyPlayed(limit: 10)
                ForEach(Array(recent.enumerated()), id: \.element.id) { idx, entry in
                    HStack(spacing: 12) {
                        Text(entry.timestamp, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 60, alignment: .trailing)

                        Circle()
                            .fill(idx < 3 ? effectivePrimary : Color.gray.opacity(0.3))
                            .frame(width: 8, height: 8)

                        CachedAsyncImage(url: entry.albumArtURI.flatMap { URL(string: $0) }, cornerRadius: 6)
                            .frame(width: 36, height: 36)
                            .onTapGesture { expandedArtEntry = entry }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.callout)
                                .lineLimit(1)
                            if !entry.artist.isEmpty {
                                Text(entry.artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if !entry.stationName.isEmpty {
                                Text(entry.stationName)
                                    .font(.caption)
                                    .foregroundStyle(.orange.opacity(0.8))
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        let source = historyManager.sourceServiceName(for: entry)
                        Text(source)
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(ServiceColor.color(for: source), in: Capsule())
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Quick Stats Pills

    private var quickStatsPills: some View {
        HStack(spacing: 12) {
            statPill(icon: "flame.fill", label: "Streak", value: "\(currentStreak)d", color: currentStreak >= 7 ? .orange : .secondary)
            statPill(icon: "trophy.fill", label: "Best", value: "\(listeningStreak)d", color: .yellow)
            statPill(icon: "chart.line.uptrend.xyaxis", label: "Avg/Day", value: String(format: "%.1f", averagePlaysPerDay), color: effectivePrimary)
            statPill(icon: "opticaldisc.fill", label: "Albums", value: "\(uniqueAlbumCount)", color: effectiveSecondary)
            statPill(icon: "antenna.radiowaves.left.and.right", label: "Stations", value: "\(uniqueStationCount)", color: .orange)
            statPill(icon: "star.fill", label: "Starred", value: "\(starredCount)", color: .yellow)
            Spacer()
        }
    }

    private func statPill(icon: String, label: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Day of Week Chart

    @State private var hoveredWeekday: String?

    private var dayOfWeekChart: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                let data = dayOfWeekDistribution

                HStack {
                    Text("Day of Week")
                        .font(.headline)
                    Spacer()
                    if let hDay = hoveredWeekday, let match = data.first(where: { $0.0 == hDay }) {
                        Text("\(match.1) plays")
                            .font(.system(size: 12, weight: .semibold))
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(hDay)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }

                Chart {
                    ForEach(data, id: \.0) { day, count in
                        BarMark(
                            x: .value("Day", day),
                            y: .value("Plays", count)
                        )
                        .foregroundStyle(effectiveBarGradient)
                        .cornerRadius(3)
                    }
                }
                .chartXSelection(value: $hoveredWeekday)
                .frame(height: 150)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Top Tracks Chart

    private var topTracksChart: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Top Tracks", systemImage: "music.note")
                    .font(.headline)

                let tracks = mostPlayedTracks.prefix(8)
                if tracks.isEmpty {
                    Text("No data").font(.caption).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(tracks.enumerated()), id: \.offset) { idx, item in
                            HStack(spacing: 8) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 16, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.0)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    if !item.1.isEmpty {
                                        Text(item.1)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Text("\(item.2)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(effectivePrimary)
                                    .monospacedDigit()
                            }
                            if idx < tracks.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Top Stations Chart

    private var topStationsChart: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Top Stations", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)

                let stations = mostPlayedStations.prefix(8)
                if stations.isEmpty {
                    Text("No station data").font(.caption).foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(stations.enumerated()), id: \.offset) { idx, item in
                            HStack(spacing: 8) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 16, alignment: .trailing)
                                Image(systemName: "radio")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange.opacity(0.8))
                                Text(item.0)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(item.1)")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(effectivePrimary)
                                    .monospacedDigit()
                            }
                            if idx < stations.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Top Albums Chart

    private var topAlbumsChart: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Top Albums", systemImage: "square.stack")
                    .font(.headline)

                let albums = mostPlayedAlbums.prefix(8)
                if albums.isEmpty {
                    Text("No data").font(.caption).foregroundStyle(.tertiary)
                } else {
                    Chart {
                        ForEach(Array(albums.enumerated()), id: \.offset) { _, item in
                            BarMark(
                                x: .value("Plays", item.1),
                                y: .value("Album", item.0)
                            )
                            .foregroundStyle(effectiveHorizontalGradient)
                            .cornerRadius(4)
                            .annotation(position: .trailing, spacing: 4) {
                                Text("\(item.1)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                                .font(.caption)
                        }
                    }
                    .chartXAxis(.hidden)
                    .frame(height: CGFloat(albums.count) * 32)
                }
            }
        }
    }

    // MARK: - Room Distribution Chart

    private var roomChart: some View {
        dashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Room Usage", systemImage: "hifispeaker.2")
                    .font(.headline)

                let rooms = roomDistribution.prefix(8)
                Chart {
                    ForEach(rooms, id: \.0) { room, count in
                        BarMark(
                            x: .value("Plays", count),
                            y: .value("Room", room)
                        )
                        .foregroundStyle(effectiveHorizontalGradient)
                        .cornerRadius(4)
                        .annotation(position: .trailing, spacing: 4) {
                            Text("\(count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { _ in
                        AxisValueLabel()
                            .font(.caption)
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(rooms.count) * 32)
            }
        }
    }

    // MARK: - Helpers

    private func dashboardCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    private func formatHour(_ hour: Int) -> String {
        if hour == 0 { return "12am" }
        if hour < 12 { return "\(hour)am" }
        if hour == 12 { return "12pm" }
        return "\(hour - 12)pm"
    }
}

// MARK: - Dashboard Stats (computed once, not per-property)

@MainActor
private struct DashboardStats {
    let totalEntries: Int
    let totalListeningHours: Double
    let uniqueArtistCount: Int
    let uniqueRoomCount: Int
    let uniqueAlbumCount: Int
    let uniqueStationCount: Int
    let dailyActivity: [(Date, Int)]
    let hourlyDistribution: [(Int, Int)]
    let peakHour: Int
    let mostPlayedArtists: [(String, Int)]
    let mostPlayedTracks: [(String, String, Int)]
    let mostPlayedStations: [(String, Int)]
    let mostPlayedAlbums: [(String, Int)]
    let sourceDistribution: [(String, Int)]
    let dayOfWeekDistribution: [(String, Int)]
    let roomDistribution: [(String, Int)]
    let listeningStreak: Int
    let currentStreak: Int
    let averagePlaysPerDay: Double
    let starredCount: Int

    init(entries: [PlayHistoryEntry], historyManager: PlayHistoryManager) {
        self.totalEntries = entries.count
        self.totalListeningHours = entries.reduce(0) { $0 + $1.duration } / 3600.0
        self.uniqueArtistCount = Set(entries.compactMap { $0.artist.isEmpty ? nil : $0.artist }).count
        self.uniqueRoomCount = Set(entries.compactMap { $0.groupName.isEmpty ? nil : $0.groupName }).count
        self.uniqueAlbumCount = Set(entries.compactMap { $0.album.isEmpty ? nil : $0.album }).count
        self.uniqueStationCount = Set(entries.compactMap { $0.stationName.isEmpty ? nil : $0.stationName }).count

        let calendar = Calendar.current
        let now = Date()

        // Daily activity (last 30 days)
        var dayCounts: [Date: Int] = [:]
        for entry in entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            dayCounts[day, default: 0] += 1
        }
        self.dailyActivity = (0..<30).reversed().map { offset in
            let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -offset, to: now)!)
            return (day, dayCounts[day] ?? 0)
        }

        // Hourly distribution
        var hourCounts = [Int](repeating: 0, count: 24)
        for entry in entries {
            hourCounts[calendar.component(.hour, from: entry.timestamp)] += 1
        }
        self.hourlyDistribution = hourCounts.enumerated().map { ($0.offset, $0.element) }
        self.peakHour = hourlyDistribution.max(by: { $0.1 < $1.1 })?.0 ?? 12

        // Day of week distribution
        let symbols = calendar.shortWeekdaySymbols
        var weekdayCounts = [Int](repeating: 0, count: 7)
        for entry in entries {
            weekdayCounts[calendar.component(.weekday, from: entry.timestamp) - 1] += 1
        }
        self.dayOfWeekDistribution = weekdayCounts.enumerated().map { (symbols[$0.offset], $0.element) }

        // Top artists
        var artistCounts: [String: Int] = [:]
        for e in entries where !e.artist.isEmpty {
            artistCounts[e.artist, default: 0] += 1
        }
        self.mostPlayedArtists = artistCounts.sorted { $0.value > $1.value }

        // Top tracks
        var trackCounts: [String: Int] = [:]
        var trackArtist: [String: String] = [:]
        for e in entries where !e.title.isEmpty {
            let key = "\(e.title)|\(e.artist)"
            trackCounts[key, default: 0] += 1
            trackArtist[key] = e.artist
        }
        self.mostPlayedTracks = trackCounts.sorted { $0.value > $1.value }.map { (key, count) in
            let parts = key.components(separatedBy: "|")
            return (parts[0], parts.count > 1 ? parts[1] : "", count)
        }

        // Top stations
        var stationCounts: [String: Int] = [:]
        for e in entries where !e.stationName.isEmpty {
            stationCounts[e.stationName, default: 0] += 1
        }
        self.mostPlayedStations = stationCounts.sorted { $0.value > $1.value }

        // Top albums
        var albumCounts: [String: Int] = [:]
        for e in entries where !e.album.isEmpty {
            albumCounts[e.album, default: 0] += 1
        }
        self.mostPlayedAlbums = albumCounts.sorted { $0.value > $1.value }

        // Source distribution
        var sourceCounts: [String: Int] = [:]
        for entry in entries {
            let source = historyManager.sourceServiceName(for: entry)
            sourceCounts[source, default: 0] += 1
        }
        self.sourceDistribution = sourceCounts.sorted { $0.value > $1.value }

        // Room distribution
        var roomCounts: [String: Int] = [:]
        for e in entries where !e.groupName.isEmpty {
            roomCounts[e.groupName, default: 0] += 1
        }
        self.roomDistribution = roomCounts.sorted { $0.value > $1.value }

        // Listening streak
        let days = Set(entries.map { calendar.startOfDay(for: $0.timestamp) }).sorted()
        var maxStreak = days.isEmpty ? 0 : 1
        var cur = 1
        for i in 1..<days.count {
            if calendar.dateComponents([.day], from: days[i-1], to: days[i]).day == 1 {
                cur += 1
                maxStreak = max(maxStreak, cur)
            } else {
                cur = 1
            }
        }
        self.listeningStreak = maxStreak

        // Current streak
        let today = calendar.startOfDay(for: now)
        let reverseDays = days.reversed()
        if let latest = reverseDays.first, (calendar.dateComponents([.day], from: latest, to: today).day ?? 99) <= 1 {
            var streak = 1
            var prev = latest
            for day in reverseDays.dropFirst() {
                if calendar.dateComponents([.day], from: day, to: prev).day == 1 {
                    streak += 1
                    prev = day
                } else { break }
            }
            self.currentStreak = streak
        } else {
            self.currentStreak = 0
        }

        // Average plays per day
        let uniqueDayCount = dayCounts.count
        self.averagePlaysPerDay = uniqueDayCount > 0 ? Double(entries.count) / Double(uniqueDayCount) : 0
        self.starredCount = entries.filter(\.starred).count
    }
}

// MARK: - Color Hex Helpers

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }

    func toHex() -> String {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return "#3B82F6" }
        let r = Int(components.redComponent * 255)
        let g = Int(components.greenComponent * 255)
        let b = Int(components.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
