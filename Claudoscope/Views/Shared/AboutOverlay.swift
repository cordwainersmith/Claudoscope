import SwiftUI

// MARK: - About View

struct AboutOverlay: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Tap anywhere to dismiss
            Rectangle()
                .fill(.ultraThinMaterial)
                .onTapGesture { onDismiss() }

            VStack(spacing: 12) {
                if let nsImage = loadAppIcon() {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                }

                Text("Claudoscope")
                    .font(.system(size: 16, weight: .medium))

                Text("Session explorer for Claude Code")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)

                Link(destination: URL(string: "https://github.com/cordwainersmith/Claudoscope")!) {
                    Text("github.com/cordwainersmith/Claudoscope")
                        .font(.system(size: 12))
                    .foregroundStyle(.blue)
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThickMaterial)
            )
        }
        .transition(.opacity)
    }
}
