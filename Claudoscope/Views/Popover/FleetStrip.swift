import SwiftUI

/// Fleet summary for the menu bar popover, styled as a strip of the Fleet
/// control-tower board. Tapping opens the dashboard on the Fleet rail.
struct FleetStrip: View {
    let working: Int
    let waiting: Int
    let blocked: Int
    let onOpen: () -> Void

    private var needsYou: Int { waiting + blocked }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 10) {
                if needsYou > 0 {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(blocked > 0 ? Tower.red : Tower.amber)
                        .symbolEffect(.pulse)
                    Text("\(needsYou) NEED\(needsYou == 1 ? "S" : "") YOU")
                        .font(Tower.mono(11, .bold))
                        .foregroundStyle(blocked > 0 ? Tower.red : Tower.amber)
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Tower.green)
                        .symbolEffect(.variableColor.iterative)
                    Text("ALL CLEAR")
                        .font(Tower.mono(11, .bold))
                        .foregroundStyle(Tower.text)
                }
                Spacer(minLength: 0)
                Text("\(working) WORKING")
                    .font(Tower.mono(10, .semibold))
                    .foregroundStyle(working > 0 ? Tower.green : Tower.faint)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Tower.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Tower.bg)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(needsYou > 0 ? Tower.amber.opacity(0.4) : Color.white.opacity(0.08)))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Fleet control")
    }
}
