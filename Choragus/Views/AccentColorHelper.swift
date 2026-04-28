/// AccentColorHelper.swift — Resolves stored color settings to SwiftUI Colors.
import SwiftUI
import SonosKit

extension StoredColor {
    /// Converts to a SwiftUI Color. Returns nil if system.
    var color: Color? {
        guard !isSystem else { return nil }
        return Color(red: red, green: green, blue: blue)
    }

    /// Converts to a SwiftUI Color with a fallback for non-optional contexts.
    func color(fallback: Color) -> Color {
        color ?? fallback
    }
}

@MainActor
extension SonosManager {
    /// Resolved accent color, nil means use system default.
    var resolvedAccentColor: Color? {
        accentColor.color
    }

    /// The effective accent color (resolved or macOS default).
    private var effectiveAccent: Color {
        resolvedAccentColor ?? .accentColor
    }

    /// Resolved playing zone icon color. System = use accent color.
    var resolvedPlayingZoneColor: Color {
        playingZoneColor.color ?? effectiveAccent
    }

    /// Resolved inactive zone icon color. System = use accent color.
    var resolvedInactiveZoneColor: Color {
        inactiveZoneColor.color ?? effectiveAccent
    }
}
