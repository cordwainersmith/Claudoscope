import SwiftUI

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
    var searchText: String = ""
    var turnDuration: TurnDuration? = nil
    var parallelToolCount: Int = 0

    private var effortLevel: EffortLevel {
        var thinkingChars = 0
        if case .blocks(let blocks) = record.message?.content {
            for block in blocks where block.type == "thinking" {
                thinkingChars += block.thinking?.count ?? 0
            }
        }
        let outputTokens = record.message?.usage?.outputTokens ?? 0
        return ObservabilityAnalyzer.classifyEffort(
            thinkingChars: thinkingChars,
            outputTokens: outputTokens,
            stopReason: record.message?.stopReason
        )
    }

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
                        .font(Typography.caption)
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
                        Text("\(formatTokens(inTok)) in / \(formatTokens(outTok)) out")
                            .font(Typography.codeSmall)
                            .foregroundStyle(.tertiary)
                    }
                }

                if turnDuration != nil || effortLevel != .low || parallelToolCount > 1 {
                    HStack(spacing: 4) {
                        if let td = turnDuration, td.durationMs > 0 {
                            TurnDurationBadge(durationMs: td.durationMs)
                        }
                        if effortLevel != .low {
                            EffortLevelBadge(level: effortLevel)
                        }
                        if parallelToolCount > 1 {
                            ParallelToolBadge(count: parallelToolCount)
                        }
                    }
                }
            }

            // Content blocks
            if !contentBlocks.isEmpty {
                ForEach(Array(contentBlocks.enumerated()), id: \.offset) { index, block in
                    contentBlockView(for: block, index: index)
                }
            } else if !textContent.isEmpty {
                CollapsibleTextView(content: textContent, fontSize: 13)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func contentBlockView(for block: ContentBlockRaw, index: Int) -> some View {
        switch block.type {
        case "text":
            if let text = block.text, !text.isEmpty {
                CollapsibleTextView(content: text, fontSize: 13)
            }

        case "thinking":
            if let thinking = block.thinking, !thinking.isEmpty {
                ThinkingBlockView(text: thinking, searchText: searchText)
            }

        case "tool_use":
            if let name = block.name, let id = block.id {
                let result = toolResultMap[id]
                ToolCallBlockView(
                    toolName: name,
                    input: block.input ?? [:],
                    resultContent: result?.content,
                    isError: result?.isError ?? false,
                    searchText: searchText
                )
            }

        default:
            EmptyView()
        }
    }
}

// MARK: - Collapsible Text Block

struct CollapsibleTextView: View {
    let content: String
    let fontSize: CGFloat
    @State private var isCollapsed = true
    @State private var fullHeight: CGFloat = 0

    private let collapseHeight: CGFloat = 300

    var body: some View {
        if isLongContent {
            VStack(alignment: .leading, spacing: 0) {
                MarkdownContentView(content: content, fontSize: fontSize)
                    .textSelection(.enabled)
                    .background(
                        GeometryReader { geo in
                            Color.clear
                                .onAppear { fullHeight = geo.size.height }
                                .onChange(of: geo.size.height) { _, h in fullHeight = h }
                        }
                    )
                    .frame(maxHeight: isCollapsed ? collapseHeight : nil, alignment: .top)
                    .clipped()

                if isCollapsed {
                    // Fade-out gradient overlay
                    LinearGradient(
                        colors: [.clear, Color(nsColor: .windowBackgroundColor)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 40)
                    .offset(y: -40)
                    .allowsHitTesting(false)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isCollapsed.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                        Text(isCollapsed ? "Show more" : "Show less")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        } else {
            MarkdownContentView(content: content, fontSize: fontSize)
                .textSelection(.enabled)
        }
    }

    private var isLongContent: Bool {
        let lineCount = content.components(separatedBy: "\n").count
        return lineCount > 15 || content.count > 1500
    }
}
