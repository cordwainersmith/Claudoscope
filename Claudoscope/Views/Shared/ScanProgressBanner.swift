import SwiftUI

/// A thin native-style banner shown at the top of the window during initial session scan.
struct ScanProgressBanner: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            if store.scanSessionsTotal > 0 {
                Text("Scanning sessions… \(store.scanSessionsProcessed) / \(store.scanSessionsTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ProgressView(
                    value: Double(store.scanSessionsProcessed),
                    total: Double(store.scanSessionsTotal)
                )
                .progressViewStyle(.linear)
                .tint(.accentColor)
                .frame(maxWidth: 200)
            } else {
                Text("Discovering sessions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
