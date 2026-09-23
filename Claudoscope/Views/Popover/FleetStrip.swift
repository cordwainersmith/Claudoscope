import SwiftUI

/// One-line fleet summary for the menu bar popover: working / waiting /
/// blocked counts. Tapping opens the dashboard on the Fleet rail.
struct FleetStrip: View {
    let working: Int
    let waiting: Int
    let blocked: Int
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Text("FLEET")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                pair(count: working, color: .okabeBlue, label: "working")
                pair(count: waiting, color: .okabeOrange, label: "waiting")
                if blocked > 0 {
                    pair(count: blocked, color: .okabeVermillion, label: "blocked")
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the Fleet view")
    }

    private func pair(count: Int, color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
