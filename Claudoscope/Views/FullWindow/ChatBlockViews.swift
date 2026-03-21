import SwiftUI

// MARK: - Thinking Block

struct ThinkingBlockView: View {
    let text: String
    var searchText: String = ""
    @State private var isExpanded = false

    private var hasSearchMatch: Bool {
        guard !searchText.isEmpty else { return false }
        return text.localizedCaseInsensitiveContains(searchText)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ScrollView {
                Text(text)
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 400)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.system(size: 11))
                Text("Thinking")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(hasSearchMatch ? Color.yellow.opacity(0.08) : .secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            hasSearchMatch
                ? RoundedRectangle(cornerRadius: 6).strokeBorder(Color.yellow.opacity(0.4), lineWidth: 1)
                : nil
        )
        .onChange(of: searchText) { _, _ in
            if hasSearchMatch { isExpanded = true }
        }
    }
}

// MARK: - Tool Call Block

struct ToolCallBlockView: View {
    let toolName: String
    let input: [String: AnyCodableValue]
    let resultContent: String?
    let isError: Bool
    var searchText: String = ""
    @State private var isExpanded = false

    private var hasSearchMatch: Bool {
        guard !searchText.isEmpty else { return false }
        let query = searchText.lowercased()
        for (_, value) in input {
            if let str = value.stringValue, str.lowercased().contains(query) { return true }
        }
        if let result = resultContent, result.lowercased().contains(query) { return true }
        return false
    }

    private var toolCategoryColor: Color { categoryColor(for: toolName) }
    private var toolIconName: String { toolIcon(for: toolName) }
    private var primaryArg: String? { primaryArgument(from: input, toolName: toolName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    Image(systemName: toolIconName)
                        .font(.system(size: 12))
                        .foregroundStyle(toolCategoryColor)

                    Text(toolName)
                        .font(Typography.bodyMedium)

                    if let arg = primaryArg {
                        Text(arg)
                            .font(Typography.code)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let result = resultContent {
                Divider()
                ScrollView {
                    Text(result)
                        .font(Typography.code)
                        .foregroundStyle(isError ? .red : .secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            }
        }
        .background(hasSearchMatch ? AnyShapeStyle(Color.yellow.opacity(0.08)) : AnyShapeStyle(.bar.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(hasSearchMatch ? AnyShapeStyle(Color.yellow.opacity(0.4)) : AnyShapeStyle(.quaternary), lineWidth: hasSearchMatch ? 1.5 : 1)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(toolCategoryColor)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onChange(of: searchText) { _, _ in
            if hasSearchMatch { isExpanded = true }
        }
    }
}
