import SwiftUI

// MARK: - Compaction Divider

struct CompactionDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.orange.opacity(0.3))
                .frame(height: 1)
            Text("Context Compacted")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Rectangle()
                .fill(.orange.opacity(0.3))
                .frame(height: 1)
        }
        .help("Earlier messages were summarized to free up context window")
        .padding(.vertical, 8)
    }
}

// MARK: - Claude Avatar

struct ClaudeAvatarView: View {
    var size: CGFloat = 20

    var body: some View {
        if let image = loadAvatar() {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        } else {
            Image(systemName: "brain.head.profile")
                .font(.system(size: size * 0.6))
                .foregroundStyle(.purple)
                .frame(width: size, height: size)
        }
    }

    private func loadAvatar() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "claude-avatar", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return image
    }
}

// MARK: - Continuation Banner

struct ContinuationBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11))
            Text("Continued from a previous session")
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
