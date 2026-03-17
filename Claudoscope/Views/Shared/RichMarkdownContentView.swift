import SwiftUI

/// A styled markdown view with accent-bordered headings, callout banners,
/// labeled code blocks, and more visual breathing room.
struct RichMarkdownContentView: View {
    let content: String
    var fontSize: CGFloat = 13

    private var blocks: [MarkdownBlock] {
        parseMarkdown(content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                richBlockView(block)
            }
        }
    }

    @ViewBuilder
    private func richBlockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            richHeadingView(level: level, text: text)

        case .paragraph(let text):
            if let callout = detectCallout(text) {
                calloutView(callout)
            } else {
                richInlineMarkdownText(text)
                    .font(.system(size: fontSize))
                    .padding(.leading, 4)
            }

        case .codeBlock(let language, let code):
            richCodeBlockView(language: language, code: code)

        case .unorderedList(let items):
            richListView(items: items, ordered: false)

        case .orderedList(let items):
            richListView(items: items, ordered: true)

        case .blockquote(let text):
            richBlockquoteView(text)

        case .table(let headers, let rows):
            richTableView(headers: headers, rows: rows)

        case .horizontalRule:
            Divider()
                .padding(.vertical, 6)

        case .empty:
            EmptyView()
        }
    }

    // MARK: - Heading with accent bar

    @ViewBuilder
    private func richHeadingView(level: Int, text: String) -> some View {
        let size: CGFloat = switch level {
        case 1: fontSize + 7
        case 2: fontSize + 4
        case 3: fontSize + 2
        default: fontSize + 1
        }

        let accentColor: Color = switch level {
        case 1: .blue
        case 2: .blue.opacity(0.7)
        default: .blue.opacity(0.4)
        }

        VStack(alignment: .leading, spacing: 0) {
            if level <= 2 {
                // Add spacing before major headings (but not if it's the first block)
                Spacer().frame(height: 4)
            }

            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accentColor)
                    .frame(width: 3)

                richInlineMarkdownText(text)
                    .font(.system(size: size, weight: level <= 2 ? .semibold : .medium))
                    .padding(.leading, 10)
            }

            if level <= 2 {
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 1)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: - Callout detection and rendering

    private struct CalloutInfo {
        let keyword: String
        let message: String
        let icon: String
        let tint: Color
    }

    private func detectCallout(_ text: String) -> CalloutInfo? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let patterns: [(prefix: String, icon: String, tint: Color)] = [
            ("CRITICAL:", "exclamationmark.octagon.fill", .red),
            ("IMPORTANT:", "exclamationmark.triangle.fill", .orange),
            ("WARNING:", "exclamationmark.triangle.fill", .orange),
            ("NOTE:", "info.circle.fill", .blue),
            ("TIP:", "lightbulb.fill", .yellow),
        ]

        for pattern in patterns {
            if trimmed.hasPrefix(pattern.prefix) {
                let message = String(trimmed.dropFirst(pattern.prefix.count)).trimmingCharacters(in: .whitespaces)
                return CalloutInfo(
                    keyword: String(pattern.prefix.dropLast()),
                    message: message,
                    icon: pattern.icon,
                    tint: pattern.tint
                )
            }
        }
        return nil
    }

    private func calloutView(_ callout: CalloutInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: callout.icon)
                .font(.system(size: 13))
                .foregroundStyle(callout.tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(callout.keyword)
                    .font(.system(size: fontSize - 1, weight: .bold))
                    .foregroundStyle(callout.tint)

                richInlineMarkdownText(callout.message)
                    .font(.system(size: fontSize))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(callout.tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(callout.tint.opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Code block with language label

    private func richCodeBlockView(language: String?, code: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lang = language, !lang.isEmpty {
                HStack {
                    Text(lang)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: fontSize - 1, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, language != nil ? 8 : 12)
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - List

    @ViewBuilder
    private func richListView(items: [ListItem], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
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
                            .foregroundStyle(.blue.opacity(0.6))
                            .frame(width: 12 + leadingPad, alignment: .trailing)
                    }

                    richInlineMarkdownText(item.text)
                        .font(.system(size: fontSize))
                }
            }
        }
        .padding(.leading, 4)
    }

    // MARK: - Blockquote

    private func richBlockquoteView(_ text: String) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.blue.opacity(0.3))
                .frame(width: 3)

            richInlineMarkdownText(text)
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .padding(.vertical, 4)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Table

    private func richTableView(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row
                HStack(spacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        Text(header)
                            .font(.system(size: fontSize - 1, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .frame(minWidth: 100, alignment: .leading)
                    }
                }
                .background(Color.primary.opacity(0.06))

                Divider()

                // Data rows
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                            // First column slightly bolder
                            if colIdx == 0 {
                                richInlineMarkdownText(cell)
                                    .font(.system(size: fontSize - 1, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .frame(minWidth: 100, alignment: .leading)
                            } else {
                                richInlineMarkdownText(cell)
                                    .font(.system(size: fontSize - 1))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .frame(minWidth: 100, alignment: .leading)
                            }
                        }
                    }
                    .background(rowIdx % 2 == 1 ? Color.primary.opacity(0.02) : .clear)

                    if rowIdx < rows.count - 1 {
                        Divider().opacity(0.4)
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

    // MARK: - Inline Markdown

    private func richInlineMarkdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(text)
    }
}
