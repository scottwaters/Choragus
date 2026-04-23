/// FirstRunWelcomeView.swift — One-time popup shown on first launch.
///
/// Points the user at the official Sonos app (required for speaker and
/// service setup) and at in-app Settings → Music for enabling services.
/// Dismissal persists via UserDefaults so the dialog never shows again.
import SwiftUI
import SonosKit

struct FirstRunWelcomeView: View {
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "hifispeaker.2.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(L10n.welcomeTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            Text(L10n.welcomeBody)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.later) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.openSettings) {
                    onOpenSettings()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// Tracks whether the first-run welcome has been shown.
enum FirstRunWelcome {
    private static let shownKey = "firstRunWelcome.shown"

    static var hasBeenShown: Bool {
        UserDefaults.standard.bool(forKey: shownKey)
    }

    static func markShown() {
        UserDefaults.standard.set(true, forKey: shownKey)
    }
}
