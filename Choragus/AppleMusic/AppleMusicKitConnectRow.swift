/// AppleMusicKitConnectRow.swift — Settings → Music Services entry
/// for the MusicKit-backed Apple Music. Surfaces the on-device
/// authorisation state so the user can connect / re-check from
/// Settings, alongside the SMAPI-driven service list.
///
/// Compiled in for every build that links MusicKit (`ENABLE_MUSICKIT`).
/// Hidden by the parent view (`AppleMusicProviderFactory.hasMusicKitSupport`)
/// on fork builds with no MusicKit linkage.
import SwiftUI
import SonosKit

struct AppleMusicKitConnectRow: View {
    @State private var provider: AppleMusicProvider = AppleMusicProviderFactory.makeCurrent()
    @State private var auth: AppleMusicAuthorisation = .notDetermined
    @State private var storefront: String?
    @State private var working = false
    /// Persists the last-known auth-is-.authorised bit so other views
    /// (notably BrowseView's MusicKit entry) can react synchronously.
    @AppStorage(UDKey.appleMusicKitConnected) private var connectedFlag: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Apple Music (MusicKit)")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(iconTint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stateTitle).font(.body)
                    if let detail = stateDetail {
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                actionButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
        .task { await refresh() }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch auth {
        case .notDetermined:
            Button("Connect") { Task { await connect() } }
                .disabled(working)
        case .authorised:
            Button("Re-check") { Task { await refresh() } }
                .disabled(working)
        case .denied:
            Button("Open System Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Media") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .noSubscription, .notApplicable:
            EmptyView()
        }
    }

    private var icon: String {
        switch auth {
        case .authorised: return "checkmark.circle.fill"
        case .denied:     return "exclamationmark.circle.fill"
        case .noSubscription: return "exclamationmark.triangle.fill"
        case .notDetermined: return "music.note"
        case .notApplicable: return "xmark.circle"
        }
    }

    private var iconTint: Color {
        switch auth {
        case .authorised: return .green
        case .denied:     return .red
        case .noSubscription: return .orange
        case .notDetermined: return .secondary
        case .notApplicable: return .secondary
        }
    }

    private var stateTitle: String {
        switch auth {
        case .authorised:
            if let storefront, !storefront.isEmpty {
                return "Connected (\(storefront.uppercased()))"
            }
            return "Connected"
        case .denied: return "Permission denied"
        case .noSubscription: return "No active subscription"
        case .notDetermined: return "Not connected"
        case .notApplicable: return "Not available in this build"
        }
    }

    private var stateDetail: String? {
        switch auth {
        case .authorised:
            return "Catalog browse, search, library, recommendations."
        case .denied:
            return "Grant Apple Music access under Privacy & Security → Media & Apple Music to enable."
        case .noSubscription:
            return "An active Apple Music subscription on the signed-in Apple ID is required."
        case .notDetermined:
            return "Allow Choragus to read your Apple Music catalogue to enable the MusicKit browse pane."
        case .notApplicable:
            return nil
        }
    }

    private func refresh() async {
        working = true
        auth = await provider.authorisation
        if auth == .authorised {
            storefront = await provider.currentStorefront()
        } else {
            storefront = nil
        }
        connectedFlag = (auth == .authorised)
        working = false
    }

    private func connect() async {
        working = true
        auth = await provider.requestAuthorisation()
        if auth == .authorised {
            storefront = await provider.currentStorefront()
        }
        connectedFlag = (auth == .authorised)
        working = false
    }
}
