import SwiftUI

// MARK: - Markdown Content View

struct MarkdownContentView: View {
    let content: String
    var fontSize: CGFloat = 13

    private var blocks: [MarkdownBlock] {
        parseMarkdown(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            headingView(level: level, text: text)

        case .paragraph(let text):
            inlineMarkdownText(text)
                .font(.system(size: fontSize))

        case .codeBlock(_, let code):
            codeBlockView(code)

        case .unorderedList(let items):
            listView(items: items, ordered: false)

        case .orderedList(let items):
            listView(items: items, ordered: true)

        case .blockquote(let text):
            blockquoteView(text)

        case .table(let headers, let rows):
            tableView(headers: headers, rows: rows)

        case .horizontalRule:
            Divider()
                .padding(.vertical, 4)

        case .empty:
            EmptyView()
        }
    }

    // MARK: - Table

    private func tableView(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(header)
                            .font(.system(size: fontSize - 1, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(minWidth: 80, alignment: .leading)
                    }
                }
                .background(Color.primary.opacity(0.06))

                Divider()

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inlineMarkdownText(cell)
                                .font(.system(size: fontSize - 1))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .frame(minWidth: 80, alignment: .leading)
                        }
                    }
                    .background(rowIdx % 2 == 1 ? Color.primary.opacity(0.02) : .clear)

                    if rowIdx < rows.count - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Heading

    @ViewBuilder
    private func headingView(level: Int, text: String) -> some View {
        let size: CGFloat = switch level {
        case 1: fontSize + 7
        case 2: fontSize + 4
        case 3: fontSize + 2
        default: fontSize + 1
        }

        inlineMarkdownText(text)
            .font(.system(size: size, weight: level <= 2 ? .semibold : .medium))
            .padding(.top, level <= 2 ? 8 : 4)
            .padding(.bottom, 2)
    }

    // MARK: - Code Block

    private func codeBlockView(_ code: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(.system(size: fontSize - 1, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - List

    @ViewBuilder
    private func listView(items: [ListItem], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    let leadingPad = CGFloat(item.indent) * 16

                    if ordered {
                        Text("\(index + 1).")
                            .font(.system(size: fontSize - 1))
                            .foregroundStyle(.secondary)
                            .frame(width: 20 + leadingPad, alignment: .trailing)
                    } else {
                        Text("\u{2022}")
                            .font(.system(size: fontSize))
                            .foregroundStyle(.secondary)
                            .frame(width: 12 + leadingPad, alignment: .trailing)
                    }

                    inlineMarkdownText(item.text)
                        .font(.system(size: fontSize))
                }
            }
        }
    }

    // MARK: - Blockquote

    private func blockquoteView(_ text: String) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 3)

            inlineMarkdownText(text)
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .padding(.vertical, 4)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Inline Markdown

    private func inlineMarkdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
