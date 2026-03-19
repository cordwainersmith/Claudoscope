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
                // Close button
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
                }

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

                VStack(spacing: 6) {
                    Link(destination: URL(string: "https://claudoscope.com/")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "globe")
                                .font(.system(size: 11))
                            Text("claudoscope.com")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.blue)
                    }
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }

                    Link(destination: URL(string: "https://github.com/cordwainersmith/Claudoscope")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "curlybraces")
                                .font(.system(size: 11))
                            Text("GitHub")
                                .font(.system(size: 12))
                        }
                        .foregroundStyle(.blue)
                    }
                    .onHover { hovering in
                        if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
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
