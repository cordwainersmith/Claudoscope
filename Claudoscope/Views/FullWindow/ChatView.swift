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
