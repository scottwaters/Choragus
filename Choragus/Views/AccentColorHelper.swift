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

    /// The theme accent for highlights and selection tints, or the macOS
    /// accent when the theme is set to System. Views draw with this rather
    /// than `Color.accentColor`: that constant is the bundle / system
    /// accent and does not follow the `.tint` applied at the window root.
    var themeAccent: Color {
        resolvedAccentColor ?? .accentColor
    }

    /// Resolved playing zone icon color. System = use accent color.
    var resolvedPlayingZoneColor: Color {
        playingZoneColor.color ?? themeAccent
    }

    /// Resolved inactive zone icon color. System = use accent color.
    var resolvedInactiveZoneColor: Color {
        inactiveZoneColor.color ?? themeAccent
    }
}
