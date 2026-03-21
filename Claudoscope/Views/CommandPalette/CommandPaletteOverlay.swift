import SwiftUI

// MARK: - Command Item

struct CommandItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String
    let keywords: [String]
    let shortcut: String?
    let action: () -> Void
}

// MARK: - Subsequence Matcher

private struct ScoredCommand {
    let command: CommandItem
    let score: Int
}

private func subsequenceScore(query: String, target: String) -> Int? {
    let queryLower = query.lowercased()
    let targetLower = target.lowercased()

    guard !queryLower.isEmpty else { return 0 }

    var score = 0
    var queryIndex = queryLower.startIndex
    var targetIndex = targetLower.startIndex
    var lastMatchIndex: String.Index?
    var consecutiveCount = 0

    while queryIndex < queryLower.endIndex, targetIndex < targetLower.endIndex {
        if queryLower[queryIndex] == targetLower[targetIndex] {
            // Consecutive character bonus
            if let last = lastMatchIndex, targetLower.index(after: last) == targetIndex {
                consecutiveCount += 1
                score += consecutiveCount * 5
            } else {
                consecutiveCount = 1
            }

            // Word boundary bonus: start of string, or preceded by space/punctuation
            if targetIndex == targetLower.startIndex {
                score += 10
            } else {
                let prev = targetLower[targetLower.index(before: targetIndex)]
                if prev == " " || prev == "." || prev == "-" || prev == "_" {
                    score += 8
                }
            }

            score += 1
            lastMatchIndex = targetIndex
            queryIndex = queryLower.index(after: queryIndex)
        }
        targetIndex = targetLower.index(after: targetIndex)
    }

    // All query characters must be matched
    guard queryIndex == queryLower.endIndex else { return nil }

    // Length penalty: prefer shorter targets
    let lengthPenalty = targetLower.count / 4
    score -= lengthPenalty

    return score
}

private func matchCommand(query: String, command: CommandItem) -> Int? {
    var bestScore: Int?

    // Try matching against title
    if let titleScore = subsequenceScore(query: query, target: command.title) {
        bestScore = titleScore
    }

    // Try matching against subtitle
    if let subtitle = command.subtitle,
       let subtitleScore = subsequenceScore(query: query, target: subtitle) {
        let adjusted = subtitleScore - 2
        if bestScore == nil || adjusted > bestScore! {
            bestScore = adjusted
        }
    }

    // Try matching against keywords
    for keyword in command.keywords {
        if let kwScore = subsequenceScore(query: query, target: keyword) {
            let adjusted = kwScore - 1
            if bestScore == nil || adjusted > bestScore! {
                bestScore = adjusted
            }
        }
    }

    return bestScore
}

// MARK: - Command Palette Overlay

struct CommandPaletteOverlay: View {
    @Binding var isPresented: Bool
    @Binding var selectedRail: RailItem
    @Binding var selectedProjectId: String?
    @Binding var selectedSessionId: String?

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var selectionSource: SelectionSource = .keyboard
    @FocusState private var isSearchFieldFocused: Bool

    private enum SelectionSource { case keyboard, mouse }

    private var commands: [CommandItem] {
        var items: [CommandItem] = []

        for rail in RailItem.allCases {
            items.append(CommandItem(
                id: "nav-\(rail.rawValue)",
                title: "Go to \(rail.label)",
                subtitle: "Navigation",
                icon: rail.icon,
                keywords: [rail.rawValue, rail.label.lowercased(), "navigate", "go"],
                shortcut: nil,
                action: {
                    selectedRail = rail
                    isPresented = false
                }
            ))
        }

        items.append(contentsOf: utilityCommands)
        return items
    }

    private var utilityCommands: [CommandItem] {
        [
            CommandItem(
                id: "search-sessions",
                title: "Search Sessions",
                subtitle: "Find a session by name or content",
                icon: "magnifyingglass",
                keywords: ["search", "find", "session", "query"],
                shortcut: nil,
                action: {
                    selectedRail = .sessions
                    isPresented = false
                }
            ),
            CommandItem(
                id: "refresh-data",
                title: "Refresh Data",
                subtitle: "Reload all projects and sessions",
                icon: "arrow.clockwise",
                keywords: ["refresh", "reload", "update", "sync"],
                shortcut: nil,
                action: {
                    isPresented = false
                    NotificationCenter.default.post(name: .commandPaletteRefresh, object: nil)
                }
            ),
            CommandItem(
                id: "clear-selection",
                title: "Clear Selection",
                subtitle: "Deselect current project and session",
                icon: "xmark.circle",
                keywords: ["clear", "deselect", "reset", "unselect"],
                shortcut: nil,
                action: {
                    selectedProjectId = nil
                    selectedSessionId = nil
                    isPresented = false
                }
            ),
            CommandItem(
                id: "go-analytics-overview",
                title: "View Cost Overview",
                subtitle: "Jump to analytics with cost breakdown",
                icon: "dollarsign.circle",
                keywords: ["cost", "spending", "money", "price", "billing"],
                shortcut: nil,
                action: {
                    selectedRail = .analytics
                    isPresented = false
                }
            ),
            CommandItem(
                id: "view-active-sessions",
                title: "View Active Sessions",
                subtitle: "Show currently running sessions",
                icon: "bolt.fill",
                keywords: ["active", "running", "live", "current"],
                shortcut: nil,
                action: {
                    selectedRail = .sessions
                    isPresented = false
                }
            ),
            CommandItem(
                id: "view-config-health",
                title: "Check Config Health",
                subtitle: "Review configuration issues and warnings",
                icon: "checkmark.shield",
                keywords: ["config", "health", "check", "issues", "warnings", "secrets"],
                shortcut: nil,
                action: {
                    selectedRail = .configHealth
                    isPresented = false
                }
            ),
            CommandItem(
                id: "view-memory",
                title: "View Memory Files",
                subtitle: "Browse CLAUDE.md and memory files",
                icon: "brain",
                keywords: ["memory", "claude", "md", "instructions"],
                shortcut: nil,
                action: {
                    selectedRail = .memory
                    isPresented = false
                }
            ),
            CommandItem(
                id: "view-hooks",
                title: "View Hooks Configuration",
                subtitle: "See configured hooks and triggers",
                icon: "arrow.triangle.turn.up.right.diamond",
                keywords: ["hooks", "triggers", "events", "automation"],
                shortcut: nil,
                action: {
                    selectedRail = .hooks
                    isPresented = false
                }
            ),
        ]
    }

    private var filteredCommands: [CommandItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return commands }

        let scored: [ScoredCommand] = commands.compactMap { cmd in
            if let score = matchCommand(query: trimmed, command: cmd) {
                return ScoredCommand(command: cmd, score: score)
            }
            return nil
        }

        return scored
            .sorted { $0.score > $1.score }
            .map { $0.command }
    }

    var body: some View {
        ZStack {
            backdrop
            paletteCard
        }
        .task {
            isSearchFieldFocused = true
        }
        .transition(.opacity)
        .animation(.easeOut(duration: Motion.quick), value: isPresented)
    }

    // MARK: - Subviews

    private var backdrop: some View {
        Color.black.opacity(0.3)
            .ignoresSafeArea()
            .onTapGesture {
                isPresented = false
            }
    }

    private var searchField: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(Typography.body)

            TextField("Type a command...", text: $query)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .focused($isSearchFieldFocused)
                .onChange(of: query) { _, _ in
                    selectedIndex = 0
                }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let results = filteredCommands
                    if results.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, command in
                            PaletteCommandRow(
                                command: command,
                                isSelected: index == selectedIndex
                            )
                            .id(command.id)
                            .onTapGesture {
                                command.action()
                            }
                            .onHover { hovering in
                                if hovering && selectedIndex != index {
                                    selectionSource = .mouse
                                    selectedIndex = index
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
            .onChange(of: selectedIndex) { _, newIndex in
                // Only auto-scroll on keyboard navigation, not mouse hover
                guard selectionSource == .keyboard else { return }
                let results = filteredCommands
                if newIndex >= 0, newIndex < results.count {
                    withAnimation(.easeOut(duration: Motion.quick)) {
                        proxy.scrollTo(results[newIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        HStack {
            Spacer()
            Text("No matching commands")
                .font(Typography.body)
                .foregroundStyle(.secondary)
                .padding(.vertical, Spacing.xl)
            Spacer()
        }
    }

    private var paletteCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(width: 500)
        .frame(maxHeight: 400)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .padding(.top, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onKeyPress(.downArrow) {
            let count = filteredCommands.count
            if count > 0 {
                selectionSource = .keyboard
                selectedIndex = min(selectedIndex + 1, count - 1)
            }
            return .handled
        }
        .onKeyPress(.upArrow) {
            selectionSource = .keyboard
            selectedIndex = max(selectedIndex - 1, 0)
            return .handled
        }
        .onKeyPress(.return) {
            let results = filteredCommands
            if selectedIndex >= 0, selectedIndex < results.count {
                results[selectedIndex].action()
            }
            return .handled
        }
        .onExitCommand {
            isPresented = false
        }
    }
}

// MARK: - Palette Command Row

private struct PaletteCommandRow: View {
    let command: CommandItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: command.icon)
                .font(Typography.body)
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 20, alignment: .center)

            labelStack

            Spacer()

            shortcutBadge
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var labelStack: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(command.title)
                .font(Typography.bodyMedium)
                .foregroundStyle(isSelected ? .white : .primary)

            if let subtitle = command.subtitle {
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            }
        }
    }

    @ViewBuilder
    private var shortcutBadge: some View {
        if let shortcut = command.shortcut {
            Text(shortcut)
                .font(Typography.codeSmall)
                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: Radius.sm)
                        .fill(isSelected ? Color.white.opacity(0.2) : Color.primary.opacity(0.06))
                )
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .fill(isSelected ? Color.accentColor : Color.clear)
            .padding(.horizontal, Spacing.xs)
    }
}

// MARK: - Notification for Refresh

extension Notification.Name {
    static let commandPaletteRefresh = Notification.Name("commandPaletteRefresh")
}
