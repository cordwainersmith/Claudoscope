import SwiftUI

struct ChatView: View {
    let session: ParsedSession
    /// Record uuid to scroll to (set by the Files tab's jump-to-chat).
    /// Consumed and cleared on appear / on change; .constant(nil) when the
    /// host has no Files tab (Cowork).
    @Binding var scrollTargetUuid: String?
    /// Navigates to the Files tab; nil hides the file-changes link (Cowork).
    var onOpenFilesTab: (() -> Void)? = nil
    @State private var isNearTop = true
    @State private var isNearBottom = false
    @State private var searchText = ""
    @State private var currentMatchIndex = 0
    @State private var blockedActionsExpanded = false

    @AppStorage("showThinking") private var showThinking = true
    @AppStorage("showToolCalls") private var showToolCalls = true

    private var filtersActive: Bool { !showThinking || !showToolCalls }

    private var turnDurations: [Int: TurnDuration] {
        let durations = ObservabilityAnalyzer.computeTurnDurations(records: session.records)
        var dict: [Int: TurnDuration] = [:]
        // Build a map from record index to turn index
        var turnIndex = 0
        var recordToTurn: [Int: Int] = [:]
        for (i, record) in session.records.enumerated() {
            if record.type == .assistant && record.message?.stopReason != nil {
                recordToTurn[i] = turnIndex
                turnIndex += 1
            }
        }
        for duration in durations {
            for (recordIdx, turn) in recordToTurn where turn == duration.turnIndex {
                dict[recordIdx] = duration
            }
        }
        return dict
    }

    private var parallelToolCounts: [Int: Int] {
        var dict: [Int: Int] = [:]
        for (i, record) in session.records.enumerated() {
            if record.type == .assistant, case .blocks(let blocks) = record.message?.content {
                let count = blocks.filter { $0.type == "tool_use" }.count
                if count > 1 {
                    dict[i] = count
                }
            }
        }
        return dict
    }

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

        // Check inside content blocks (thinking, tool inputs, tool results).
        // Gate by the Focus filters so search only matches content that is actually
        // rendered; hidden blocks are never shown, so they must not match either.
        if let content = record.message?.content, case .blocks(let blocks) = content {
            for block in blocks {
                if showThinking, let thinking = block.thinking, thinking.lowercased().contains(query) {
                    return true
                }
                if showToolCalls, let input = block.input {
                    for (_, value) in input {
                        if let str = value.stringValue, str.lowercased().contains(query) {
                            return true
                        }
                    }
                }
                if showToolCalls, let toolId = block.id, let result = session.toolResultMap[toolId] {
                    if result.content.lowercased().contains(query) {
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Whether a record renders anything under the current Focus filters.
    /// Consulted for every row: with both switches on it drops only records that
    /// render nothing (empty streaming fragments, blank tool_result/user rows); with
    /// a filter active it also hides thinking/tool turns. Kept in sync with
    /// `AssistantMessageView` via `chatBlockIsVisible`.
    private func isRecordVisible(_ record: ParsedRecordRaw) -> Bool {
        switch record.type {
        case .user:
            return !strippedUserText(record.message?.content?.textContent).isEmpty
        case .assistant:
            if case .blocks(let blocks) = record.message?.content,
               blocks.contains(where: { chatBlockIsVisible($0, showThinking: showThinking, showToolCalls: showToolCalls) }) {
                return true
            }
            return !(record.message?.content?.textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .system:
            return record.subtype == "compact_boundary"   // CompactionDivider, never filtered
        default:
            return false
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                VStack(spacing: 0) {
                    if session.isSubagent {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 12))
                            Text("Subagent Session")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08))
                    }
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
            .onAppear { consumeScrollTarget(proxy: proxy) }
            .onChange(of: scrollTargetUuid) { _, _ in consumeScrollTarget(proxy: proxy) }
        }
    }

    /// Jump-to-chat: map the target uuid to its parse-order index (the
    /// `record-\(index)` anchors), un-hide tool calls if the record is
    /// filtered out, then scroll on the next runloop so the anchor exists.
    private func consumeScrollTarget(proxy: ScrollViewProxy) {
        guard let target = scrollTargetUuid else { return }
        guard let index = session.records.firstIndex(where: { $0.uuid == target }) else {
            scrollTargetUuid = nil
            return
        }
        if !isRecordVisible(session.records[index]) {
            showToolCalls = true
        }
        Task { @MainActor in
            withAnimation {
                proxy.scrollTo("record-\(index)", anchor: .center)
            }
            scrollTargetUuid = nil
        }
    }

    private func searchBar(proxy: ScrollViewProxy) -> some View {
        ChatSearchBar(
            searchText: $searchText,
            currentMatchIndex: $currentMatchIndex,
            matchCount: matchingIndices.count,
            showThinking: $showThinking,
            showToolCalls: $showToolCalls,
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
        let fileChanges = FileHistoryService.summarize(records: session.records)
        let checkpoints = FileHistoryService.checkpointMessageIds(records: session.records)
        let blockedActions = ObservabilityAnalyzer.extractBlockedActions(from: extractToolCalls(from: session))
        // Keep original offsets so `record-\(index)` ids, turnDurations, parallelToolCounts,
        // and search scrollTo stay aligned. Always drop records that render nothing
        // (empty streaming fragments, blank tool_result/user rows); when a Focus filter
        // is active, isRecordVisible additionally hides thinking/tool turns.
        let pairs = Array(session.records.enumerated())
        let shown = pairs.filter { isRecordVisible($0.element) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Color.clear.frame(height: 0).id("chat-top")

                if session.parentSessionId != nil {
                    ContinuationBanner()
                }

                if !blockedActions.isEmpty {
                    blockedActionsSection(blockedActions)
                }

                if !fileChanges.isEmpty, onOpenFilesTab != nil {
                    fileChangesLink
                }

                if filtersActive && shown.isEmpty {
                    EmptyStateView(
                        icon: "line.3.horizontal.decrease.circle",
                        title: "Nothing to show with these filters",
                        message: "This session has only thinking and tool activity. Turn a filter back on to see it."
                    )
                    .padding(.top, 40)
                } else {
                    ForEach(shown, id: \.offset) { index, record in
                        searchHighlightedRecord(record: record, index: index, checkpoints: checkpoints)
                    }
                }

                Color.clear.frame(height: 0).id("chat-bottom")

                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollBottomPreferenceKey.self,
                        value: geo.frame(in: .named("chatScroll")).maxY
                    )
                }
                .frame(height: 0)
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
        }
        .onPreferenceChange(ScrollBottomPreferenceKey.self) { bottomY in
            isNearBottom = bottomY < 50
        }
    }

    @ViewBuilder
    private func searchHighlightedRecord(record: ParsedRecordRaw, index: Int, checkpoints: Set<String>) -> some View {
        let isMatch = matchingIndices.contains(index)
        let isCurrentMatch = !matchingIndices.isEmpty
            && matchingIndices.indices.contains(currentMatchIndex)
            && matchingIndices[currentMatchIndex] == index
        let borderColor: Color = isCurrentMatch ? .orange : (isMatch ? .yellow : .clear)
        let borderWidth: CGFloat = isCurrentMatch ? 2 : 1
        let bgColor: Color = isCurrentMatch ? Color.orange.opacity(0.08) : (isMatch ? Color.yellow.opacity(0.05) : .clear)

        recordView(for: record, index: index, checkpoints: checkpoints)
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
                        .font(Typography.bodyMedium)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scroll to top")
            }

            if !isNearBottom {
                Button {
                    withAnimation { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(Typography.bodyMedium)
                        .frame(width: 32, height: 32)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Scroll to bottom")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func recordView(for record: ParsedRecordRaw, index: Int, checkpoints: Set<String>) -> some View {
        switch record.type {
        case .user:
            UserMessageBubble(record: record)

        case .assistant:
            let isCheckpoint = record.uuid.map { checkpoints.contains($0) } ?? false
            VStack(alignment: .leading, spacing: 4) {
                if isCheckpoint {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10))
                        Text("Checkpoint")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                AssistantMessageView(
                    record: record,
                    toolResultMap: session.toolResultMap,
                    searchText: searchText,
                    turnDuration: turnDurations[index],
                    parallelToolCount: parallelToolCounts[index] ?? 0,
                    showThinking: showThinking,
                    showToolCalls: showToolCalls
                )
            }

        case .system:
            if record.subtype == "compact_boundary" {
                CompactionDivider()
            }

        default:
            EmptyView()
        }
    }

    /// Slim deep-link into the Files tab. Deliberately count-free: the
    /// snapshot-based summary here and the patch-based Files tab can disagree
    /// (subagent edits), so only one authoritative number is ever shown.
    private var fileChangesLink: some View {
        Button {
            onOpenFilesTab?()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 12))
                Text("View file changes")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("diffs")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(12)
            .background(.bar)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func blockedActionsSection(_ actions: [BlockedAction]) -> some View {
        DisclosureGroup(isExpanded: $blockedActionsExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(actions) { action in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(action.kind.label)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.15))
                                .foregroundStyle(.orange)
                                .clipShape(Capsule())
                            Text(action.command ?? action.toolName)
                                .font(Typography.code)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(action.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "hand.raised")
                    .font(.system(size: 12))
                Text("Blocked & denied actions (\(actions.count))")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.orange)
        }
        .padding(12)
        .background(.bar)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
    @Binding var showThinking: Bool
    @Binding var showToolCalls: Bool
    let onNavigate: (SearchDirection) -> Void

    private var filtersActive: Bool { !showThinking || !showToolCalls }

    private var filterLabel: String {
        switch (showThinking, showToolCalls) {
        case (true, true):   return "Filter"
        case (false, false): return "Focus"
        case (false, true):  return "Hiding thinking"
        case (true, false):  return "Hiding tools"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(Typography.body)
                .foregroundStyle(.secondary)

            TextField("Search in conversation...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit {
                    onNavigate(.next)
                }

            if !searchText.isEmpty {
                Text(matchCount == 0 ? "No matches" : "\(currentMatchIndex + 1) of \(matchCount)")
                    .font(Typography.code)
                    .foregroundStyle(.secondary)

                Button { onNavigate(.previous) } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(matchCount == 0)

                Button { onNavigate(.next) } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
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
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Menu {
                Toggle("Focus mode", isOn: Binding(
                    get: { !showThinking && !showToolCalls },
                    set: { on in showThinking = !on; showToolCalls = !on }
                ))
                Divider()
                Toggle("Thinking", isOn: $showThinking)
                Toggle("Tool & MCP calls", isOn: $showToolCalls)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: filtersActive
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 12))
                    Text(filterLabel)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(filtersActive ? Color.accentColor : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    filtersActive ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary),
                    in: Capsule()
                )
                .contentShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Message filters")
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

private struct ScrollBottomPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
