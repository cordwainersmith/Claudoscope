import SwiftUI

// MARK: - Markdown Block Types

private enum MarkdownBlock: Identifiable {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case codeBlock(language: String?, code: String)
    case unorderedList(items: [ListItem])
    case orderedList(items: [ListItem])
    case blockquote(text: String)
    case table(headers: [String], rows: [[String]])
    case horizontalRule
    case empty

    var id: String {
        switch self {
        case .heading(_, let text): return "h-\(text.hashValue)"
        case .paragraph(let text): return "p-\(text.hashValue)"
        case .codeBlock(_, let code): return "code-\(code.hashValue)"
        case .unorderedList(let items): return "ul-\(items.hashValue)"
        case .orderedList(let items): return "ol-\(items.hashValue)"
        case .blockquote(let text): return "bq-\(text.hashValue)"
        case .table(let headers, _): return "tbl-\(headers.hashValue)"
        case .horizontalRule: return "hr-\(UUID().uuidString)"
        case .empty: return "empty-\(UUID().uuidString)"
        }
    }
}

private struct ListItem: Hashable {
    let text: String
    let indent: Int
}

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

// MARK: - Rich Markdown Content View

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

// MARK: - Markdown Parser

private func parseMarkdown(_ input: String) -> [MarkdownBlock] {
    let lines = input.components(separatedBy: "\n")
    var blocks: [MarkdownBlock] = []
    var i = 0

    while i < lines.count {
        let line = lines[i]
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Empty line
        if trimmed.isEmpty {
            i += 1
            continue
        }

        // Fenced code block
        if trimmed.hasPrefix("```") {
            let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var codeLines: [String] = []
            i += 1
            while i < lines.count {
                if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    i += 1
                    break
                }
                codeLines.append(lines[i])
                i += 1
            }
            blocks.append(.codeBlock(
                language: language.isEmpty ? nil : language,
                code: codeLines.joined(separator: "\n")
            ))
            continue
        }

        // Table: starts with a pipe-delimited line, followed by a separator line
        if trimmed.hasPrefix("|") && i + 1 < lines.count {
            let nextTrimmed = lines[i + 1].trimmingCharacters(in: .whitespaces)
            if nextTrimmed.hasPrefix("|") && nextTrimmed.range(of: #"[-:]{3,}"#, options: .regularExpression) != nil {
                let headerCells = parseTableRow(trimmed)
                var dataRows: [[String]] = []
                i += 2 // skip header + separator
                while i < lines.count {
                    let rowLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if rowLine.hasPrefix("|") {
                        dataRows.append(parseTableRow(rowLine))
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.table(headers: headerCells, rows: dataRows))
                continue
            }
        }

        // Horizontal rule
        if trimmed.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil {
            blocks.append(.horizontalRule)
            i += 1
            continue
        }

        // Heading
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            if level <= 6 {
                let headingText = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: headingText))
                i += 1
                continue
            }
        }

        // Blockquote
        if trimmed.hasPrefix(">") {
            var quoteLines: [String] = []
            while i < lines.count {
                let l = lines[i].trimmingCharacters(in: .whitespaces)
                if l.hasPrefix(">") {
                    let content = String(l.dropFirst(1)).trimmingCharacters(in: .init(charactersIn: " "))
                    quoteLines.append(content)
                    i += 1
                } else if l.isEmpty {
                    break
                } else {
                    break
                }
            }
            blocks.append(.blockquote(text: quoteLines.joined(separator: "\n")))
            continue
        }

        // Unordered list
        if trimmed.range(of: #"^[-*+] "#, options: .regularExpression) != nil {
            var items: [ListItem] = []
            while i < lines.count {
                let l = lines[i]
                let lt = l.trimmingCharacters(in: .whitespaces)
                if lt.range(of: #"^[-*+] "#, options: .regularExpression) != nil {
                    let indent = l.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
                    let bulletIdx = lt.index(lt.startIndex, offsetBy: 2)
                    let itemText = String(lt[bulletIdx...])
                    items.append(ListItem(text: itemText, indent: indent))
                    i += 1
                } else if lt.isEmpty {
                    break
                } else {
                    // Continuation line, append to last item
                    if !items.isEmpty {
                        let last = items.removeLast()
                        items.append(ListItem(text: last.text + " " + lt, indent: last.indent))
                    }
                    i += 1
                }
            }
            if !items.isEmpty {
                blocks.append(.unorderedList(items: items))
            }
            continue
        }

        // Ordered list
        if trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil {
            var items: [ListItem] = []
            while i < lines.count {
                let l = lines[i]
                let lt = l.trimmingCharacters(in: .whitespaces)
                if lt.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil {
                    let indent = l.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
                    // Drop the number, dot/paren, and space
                    let afterNum = lt.drop(while: { $0.isNumber })
                    let afterDot = afterNum.dropFirst() // drop . or )
                    let itemText = String(afterDot).trimmingCharacters(in: .init(charactersIn: " "))
                    items.append(ListItem(text: itemText, indent: indent))
                    i += 1
                } else if lt.isEmpty {
                    break
                } else {
                    if !items.isEmpty {
                        let last = items.removeLast()
                        items.append(ListItem(text: last.text + " " + lt, indent: last.indent))
                    }
                    i += 1
                }
            }
            if !items.isEmpty {
                blocks.append(.orderedList(items: items))
            }
            continue
        }

        // Paragraph: collect consecutive non-empty, non-special lines
        var paraLines: [String] = []
        while i < lines.count {
            let l = lines[i]
            let lt = l.trimmingCharacters(in: .whitespaces)
            if lt.isEmpty || lt.hasPrefix("```") || lt.hasPrefix("#") || lt.hasPrefix(">") || lt.hasPrefix("|") ||
               lt.range(of: #"^[-*+] "#, options: .regularExpression) != nil ||
               lt.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil ||
               lt.range(of: #"^[-*_]{3,}$"#, options: .regularExpression) != nil {
                break
            }
            paraLines.append(lt)
            i += 1
        }
        if !paraLines.isEmpty {
            blocks.append(.paragraph(text: paraLines.joined(separator: " ")))
        }
    }

    return blocks
}

/// Split a markdown table row like "| A | B | C |" into ["A", "B", "C"].
private func parseTableRow(_ line: String) -> [String] {
    var trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
    if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
    return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}
