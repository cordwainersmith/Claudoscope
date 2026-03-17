import SwiftUI

// MARK: - Markdown Block Types

enum MarkdownBlock: Identifiable {
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

struct ListItem: Hashable {
    let text: String
    let indent: Int
}

// MARK: - Markdown Parser

func parseMarkdown(_ input: String) -> [MarkdownBlock] {
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
func parseTableRow(_ line: String) -> [String] {
    var trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
    if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
    return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
}
