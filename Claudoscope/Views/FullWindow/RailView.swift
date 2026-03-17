import SwiftUI

struct RailView: View {
    @Binding var selected: RailItem

    var body: some View {
        VStack(spacing: 4) {
            // Primary items
            ForEach(RailItem.primaryItems, id: \.self) { item in
                RailButton(item: item, isSelected: selected == item) {
                    selected = item
                }
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            // Config items
            ForEach(RailItem.configItems, id: \.self) { item in
                RailButton(item: item, isSelected: selected == item) {
                    selected = item
                }
            }

            Spacer()

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            // Settings
            RailButton(item: .settings, isSelected: selected == .settings) {
                selected = .settings
            }
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .frame(width: 56)
        .background(.bar)
    }
}

private struct RailButton: View {
    let item: RailItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .frame(width: 28, height: 22)
                Text(item.label)
                    .font(Typography.caption)
                    .lineLimit(1)
            }
            .frame(width: 48, height: 40)
            .background(isSelected ? Color.accentColor.opacity(0.15) : .clear)
            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.label == "MCPs" ? "MCP Servers (Model Context Protocol)" : item.label)
    }
}
