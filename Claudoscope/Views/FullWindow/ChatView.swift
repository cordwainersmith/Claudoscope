import SwiftUI

struct ChatView: View {
    let session: ParsedSession

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // Continuation banner
                    if session.parentSessionId != nil {
                        ContinuationBanner()
                    }

                    ForEach(Array(session.records.enumerated()), id: \.offset) { index, record in
                        recordView(for: record, index: index)
                    }
                }
                .padding(24)
            }
        }
    }

    @ViewBuilder
    private func recordView(for record: ParsedRecordRaw, index: Int) -> some View {
        switch record.type {
        case .user:
            UserMessageBubble(record: record)

        case .assistant:
            AssistantMessageView(record: record, toolResultMap: session.toolResultMap)

        case .system:
            if record.subtype == "compact_boundary" {
                CompactionDivider()
            }

        default:
            EmptyView()
        }
    }
}

// MARK: - User Message

struct UserMessageBubble: View {
    let record: ParsedRecordRaw

    private var displayText: String {
        guard let content = record.message?.content else { return "" }
        var text = content.textContent
        // Strip system tags
        text = text.replacingOccurrences(of: #"<system-reminder>[\s\S]*?</system-reminder>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<local-command-caveat>[\s\S]*?</local-command-caveat>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<user-prompt-submit-hook>[\s\S]*?</user-prompt-submit-hook>"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        if !displayText.isEmpty {
            VStack(alignment: .trailing, spacing: 4) {
                MarkdownContentView(content: displayText, fontSize: 13)
                    .textSelection(.enabled)
                    .padding(12)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 600, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

// MARK: - Assistant Message

struct AssistantMessageView: View {
    let record: ParsedRecordRaw
    let toolResultMap: [String: ToolResultEntry]

    private var contentBlocks: [ContentBlockRaw] {
        guard let content = record.message?.content,
              case .blocks(let blocks) = content else { return [] }
        return blocks
    }

    private var textContent: String {
        record.message?.content?.textContent ?? ""
    }

    private var modelName: String? {
        record.message?.model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with Claude avatar and model badge
            HStack(spacing: 6) {
                ClaudeAvatarView(size: 20)

                if let model = modelName {
                    let family = getModelFamily(model)
                    Text(family)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.purple.opacity(0.1))
                        .clipShape(Capsule())
                }

                Spacer()

                if let usage = record.message?.usage {
                    let inTok = usage.inputTokens ?? 0
                    let outTok = usage.outputTokens ?? 0
                    if inTok + outTok > 0 {
                        Text("\(formatTokens(inTok))in / \(formatTokens(outTok))out")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Content blocks
            if !contentBlocks.isEmpty {
                ForEach(Array(contentBlocks.enumerated()), id: \.offset) { index, block in
                    contentBlockView(for: block, index: index)
                }
            } else if !textContent.isEmpty {
                MarkdownContentView(content: textContent, fontSize: 13)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func contentBlockView(for block: ContentBlockRaw, index: Int) -> some View {
        switch block.type {
        case "text":
            if let text = block.text, !text.isEmpty {
                MarkdownContentView(content: text, fontSize: 13)
                    .textSelection(.enabled)
            }

        case "thinking":
            if let thinking = block.thinking, !thinking.isEmpty {
                ThinkingBlockView(text: thinking)
            }

        case "tool_use":
            if let name = block.name, let id = block.id {
                let result = toolResultMap[id]
                ToolCallBlockView(
                    toolName: name,
                    input: block.input ?? [:],
                    resultContent: result?.content,
                    isError: result?.isError ?? false
                )
            }

        default:
            EmptyView()
        }
    }
}

// MARK: - Thinking Block

struct ThinkingBlockView: View {
    let text: String
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxHeight: 200)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.system(size: 10))
                Text("Thinking")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Tool Call Block

struct ToolCallBlockView: View {
    let toolName: String
    let input: [String: AnyCodableValue]
    let resultContent: String?
    let isError: Bool
    @State private var isExpanded = false

    private var categoryColor: Color {
        let readTools = ["Read", "Glob", "Grep", "LSP", "WebFetch", "WebSearch"]
        let writeTools = ["Write", "Edit", "NotebookEdit"]
        let execTools = ["Bash", "Agent", "Skill"]

        if readTools.contains(toolName) { return Color(red: 0.52, green: 0.72, blue: 0.92) } // #85B7EB
        if writeTools.contains(toolName) { return Color(red: 0.36, green: 0.79, blue: 0.65) } // #5DCAA5
        if execTools.contains(toolName) { return Color(red: 0.83, green: 0.66, blue: 0.26) } // #D4A843
        return .secondary
    }

    private var toolIcon: String {
        switch toolName {
        case "Read": return "doc.text"
        case "Write": return "doc.text.fill"
        case "Edit": return "pencil"
        case "Bash": return "terminal"
        case "Grep", "Glob": return "magnifyingglass"
        case "Agent": return "person.2"
        case "WebFetch", "WebSearch": return "globe"
        default: return "wrench"
        }
    }

    private var primaryArg: String? {
        switch toolName {
        case "Bash": return input["command"]?.stringValue
        case "Read", "Write", "Edit": return input["file_path"]?.stringValue
        case "Grep", "Glob": return input["pattern"]?.stringValue
        case "Agent": return input["description"]?.stringValue
        default: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    Image(systemName: toolIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(categoryColor)

                    Text(toolName)
                        .font(.system(size: 12, weight: .medium))

                    if let arg = primaryArg {
                        Text(arg)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    if isError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
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
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(isError ? .red : .secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 300)
            }
        }
        .background(.bar.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(categoryColor)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Compaction Divider

struct CompactionDivider: View {
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(.orange.opacity(0.3))
                .frame(height: 1)
            Text("context compacted")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Rectangle()
                .fill(.orange.opacity(0.3))
                .frame(height: 1)
        }
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
        guard let url = Bundle.module.url(forResource: "claude-avatar", withExtension: "png"),
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
                .font(.system(size: 10))
            Text("Continued from a previous session")
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
