import SwiftUI

struct ChatView: View {
    let session: ParsedSession
    @State private var isNearTop = true
    @State private var isNearBottom = false
    @State private var searchText = ""
    @State private var currentMatchIndex = 0

    private var matchingIndices: [Int] {
        guard !searchText.isEmpty else { return [] }
        let query = searchText.lowercased()
        return session.records.enumerated().compactMap { index, record in
            guard record.type == .user || record.type == .assistant else { return nil }
            if recordContainsQuery(record, query: query) { return index }
            return nil
        }
    }

    private func recordContainsQuery(_ record: ParsedRecordRaw, query: String) -> Bool {
        // Check top-level text
        if let textContent = record.message?.content?.textContent,
           textContent.lowercased().contains(query) {
            return true
        }

        // Check inside content blocks (thinking, tool inputs, tool results)
        if let content = record.message?.content, case .blocks(let blocks) = content {
            for block in blocks {
                if let thinking = block.thinking, thinking.lowercased().contains(query) {
                    return true
                }
                if let input = block.input {
                    for (_, value) in input {
                        if let str = value.stringValue, str.lowercased().contains(query) {
                            return true
                        }
                    }
                }
                if let toolId = block.id, let result = session.toolResultMap[toolId] {
                    if result.content.lowercased().contains(query) {
                        return true
                    }
                }
            }
        }
        return false
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    searchBar(proxy: proxy)
                    chatScrollView
                }
                scrollButtons(proxy: proxy)
            }
            .onChange(of: searchText) { _, _ in
                currentMatchIndex = 0
                if let first = matchingIndices.first {
                    withAnimation {
                        proxy.scrollTo("record-\(first)", anchor: .center)
                    }
                }
            }
        }
    }

    private func searchBar(proxy: ScrollViewProxy) -> some View {
        ChatSearchBar(
            searchText: $searchText,
            currentMatchIndex: $currentMatchIndex,
            matchCount: matchingIndices.count,
            onNavigate: { direction in
                guard !matchingIndices.isEmpty else { return }
                if direction == .next {
                    currentMatchIndex = (currentMatchIndex + 1) % matchingIndices.count
                } else {
                    currentMatchIndex = (currentMatchIndex - 1 + matchingIndices.count) % matchingIndices.count
                }
                let targetIndex = matchingIndices[currentMatchIndex]
                withAnimation {
                    proxy.scrollTo("record-\(targetIndex)", anchor: .center)
                }
            }
        )
    }

    private var chatScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Color.clear.frame(height: 0).id("chat-top")

                if session.parentSessionId != nil {
                    ContinuationBanner()
                }

                ForEach(Array(session.records.enumerated()), id: \.offset) { index, record in
                    searchHighlightedRecord(record: record, index: index)
                }

                Color.clear.frame(height: 0).id("chat-bottom")
            }
            .padding(24)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: geo.frame(in: .named("chatScroll")).origin.y
                    )
                }
            )
        }
        .coordinateSpace(name: "chatScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
            isNearTop = offset > -50
            isNearBottom = false
        }
    }

    @ViewBuilder
    private func searchHighlightedRecord(record: ParsedRecordRaw, index: Int) -> some View {
        let isMatch = matchingIndices.contains(index)
        let isCurrentMatch = !matchingIndices.isEmpty
            && matchingIndices.indices.contains(currentMatchIndex)
            && matchingIndices[currentMatchIndex] == index
        let borderColor: Color = isCurrentMatch ? .orange : (isMatch ? .yellow : .clear)
        let borderWidth: CGFloat = isCurrentMatch ? 2 : 1
        let bgColor: Color = isCurrentMatch ? Color.orange.opacity(0.08) : (isMatch ? Color.yellow.opacity(0.05) : .clear)

        recordView(for: record, index: index)
            .id("record-\(index)")
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
                    .padding(-4)
            )
            .background(bgColor)
    }

    private func scrollButtons(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 8) {
            if !isNearTop {
                Button {
                    withAnimation { proxy.scrollTo("chat-top", anchor: .top) }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
            }

            Button {
                withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    @ViewBuilder
    private func recordView(for record: ParsedRecordRaw, index: Int) -> some View {
        switch record.type {
        case .user:
            UserMessageBubble(record: record)

        case .assistant:
            AssistantMessageView(record: record, toolResultMap: session.toolResultMap, searchText: searchText)

        case .system:
            if record.subtype == "compact_boundary" {
                CompactionDivider()
            }

        default:
            EmptyView()
        }
    }
}

// MARK: - Search Bar

enum SearchDirection {
    case next, previous
}

struct ChatSearchBar: View {
    @Binding var searchText: String
    @Binding var currentMatchIndex: Int
    let matchCount: Int
    let onNavigate: (SearchDirection) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            TextField("Search in conversation...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit {
                    onNavigate(.next)
                }

            if !searchText.isEmpty {
                Text(matchCount == 0 ? "No matches" : "\(currentMatchIndex + 1) of \(matchCount)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Button { onNavigate(.previous) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)

                Button { onNavigate(.next) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)

                Button {
                    searchText = ""
                    currentMatchIndex = 0
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

// MARK: - Scroll Offset Preference Key

private struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Collapsible Text Block

private struct CollapsibleTextView: View {
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
                            .font(.system(size: 9, weight: .bold))
                        Text(isCollapsed ? "Show more" : "Show less")
                            .font(.system(size: 11, weight: .medium))
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
        .background(hasSearchMatch ? AnyShapeStyle(Color.yellow.opacity(0.08)) : AnyShapeStyle(.bar.opacity(0.5)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(hasSearchMatch ? AnyShapeStyle(Color.yellow.opacity(0.4)) : AnyShapeStyle(.quaternary), lineWidth: hasSearchMatch ? 1.5 : 1)
        )
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(categoryColor)
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .onChange(of: searchText) { _, _ in
            if hasSearchMatch { isExpanded = true }
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
        guard let url = Bundle.main.url(forResource: "claude-avatar", withExtension: "png"),
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
