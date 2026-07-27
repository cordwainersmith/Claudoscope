import SwiftUI

/// One-time celebration bar across the top of the dashboard for a milestone release.
/// Dismissal is recorded per version rather than as a boolean, so bumping
/// `MilestoneBanner.version` is all a future milestone needs to show it again.
struct MilestoneBanner: View {
    let onSeeWhatsNew: () -> Void
    let onDismiss: () -> Void

    /// The only app version this banner appears on. A fresh install of any later
    /// version never sees it.
    static let version = "1.0.0"

    private static var isCurrentRelease: Bool {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String == version
    }

    /// Whether the banner should render, given the version already dismissed.
    static func shouldShow(dismissedVersion: String) -> Bool {
        isCurrentRelease && dismissedVersion != version
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("🎉")
                .font(.system(size: 14))

            Text("Claudoscope 1.0")
                .font(.system(size: 13, weight: .semibold))

            Text("Sessions now persist between launches, with cost alerts, notifications, and per-file diffs.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Button("See what's new", action: onSeeWhatsNew)
                .buttonStyle(.link)
                .font(Typography.body)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}
