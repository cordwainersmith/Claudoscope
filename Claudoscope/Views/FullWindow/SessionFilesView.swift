import SwiftUI
import AppKit

/// Session-detail Files tab: every file Claude edited or wrote in the session,
/// with per-edit diffs rendered verbatim from the CLI's structuredPatch hunks.
/// Post-hoc review surface; same freshness semantics as the Chat tab.
struct SessionFilesView: View {
    let session: ParsedSession
    /// Called with a record uuid in the VIEWED transcript; the parent switches
    /// to the Chat tab and scrolls there.
    let onJumpToChat: (String) -> Void

    @Environment(SessionStore.self) private var store
    // Expansion state lives here, not in the cards, so LazyVStack recycling
    // cannot collapse them (the AgentTreeView.expandedNodes pattern).
    @State private var expandedFiles: Set<String> = []
    @State private var fullyShownEvents: Set<String> = []
    @State private var loadAttempted = false

    private var locatorKey: String {
        store.fileChangesKey(for: session)
    }

    /// Only trust the store's set when it belongs to this session.
    private var changeSet: FileChangeSet? {
        guard let set = store.fileChangeSet, set.sessionKey == locatorKey else { return nil }
        return set
    }

    var body: some View {
        Group {
            if let set = changeSet {
                if set.files.isEmpty {
                    EmptyStateView(
                        icon: "doc.text",
                        title: "No file changes",
                        message: "Claude did not edit or write any files in this session."
                    )
                } else {
                    filesList(set)
                }
            } else if store.fileChangesLoading || !loadAttempted {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    icon: "exclamationmark.triangle",
                    title: "File changes unavailable",
                    message: "Could not read this session's transcript."
                )
            }
        }
        .task(id: locatorKey) {
            await store.loadFileChanges(for: session)
            loadAttempted = true
        }
    }

    // MARK: - List

    private func filesList(_ set: FileChangeSet) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.md) {
                summaryStrip(set)
                ForEach(set.files) { file in
                    FileChangeCard(
                        file: file,
                        diskState: store.fileDiskStates[file.path] ?? .unknown,
                        isExpanded: expandedFiles.contains(file.path),
                        fullyShownEvents: $fullyShownEvents,
                        onToggle: {
                            withAnimation(.easeInOut(duration: Motion.quick)) {
                                if expandedFiles.contains(file.path) {
                                    expandedFiles.remove(file.path)
                                } else {
                                    expandedFiles.insert(file.path)
                                }
                            }
                        },
                        onJumpToChat: onJumpToChat
                    )
                }
            }
            .padding(Spacing.xl)
        }
    }

    private func summaryStrip(_ set: FileChangeSet) -> some View {
        HStack(spacing: Spacing.sm) {
            fileStat("Files", "\(set.files.count)", color: .primary)
            fileStat("Added", "+\(set.totalAdditions)", color: Color(nsColor: .systemGreen))
            fileStat("Removed", "\u{2212}\(set.totalDeletions)", color: Color(nsColor: .systemRed))
            fileStat("Edits", "\(set.totalEvents)", color: .primary)
        }
        .padding(.bottom, Spacing.xs)
    }

    private func fileStat(_ title: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(AnyShapeStyle(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }
}

// MARK: - File card

private struct FileChangeCard: View {
    let file: ChangedFile
    let diskState: FileDiskState
    let isExpanded: Bool
    @Binding var fullyShownEvents: Set<String>
    let onToggle: () -> Void
    let onJumpToChat: (String) -> Void

    @State private var isHovering = false
    @State private var justCopied = false

    private var hasSubagentEvents: Bool {
        file.events.contains { $0.agentLabel != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                VStack(alignment: .leading, spacing: Spacing.md) {
                    ForEach(Array(file.events.enumerated()), id: \.element.id) { index, event in
                        EditEventView(
                            event: event,
                            ordinal: index + 1,
                            displayPath: file.displayPath,
                            isFullyShown: fullyShownEvents.contains(event.id),
                            onToggleFullyShown: {
                                if fullyShownEvents.contains(event.id) {
                                    fullyShownEvents.remove(event.id)
                                } else {
                                    fullyShownEvents.insert(event.id)
                                }
                            },
                            onJumpToChat: onJumpToChat
                        )
                    }
                }
                .padding(Spacing.md)
            }
        }
        .background(.bar.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
        .contextMenu { actionButtons(iconOnly: false) }
    }

    // Action buttons are SIBLINGS of the expand toggle, not children of its
    // label: macOS does not reliably show .help() tooltips (or route clicks)
    // for controls nested inside another button.
    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    Image(systemName: "doc.text")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Text(file.displayPath)
                        .font(Typography.code)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if file.isNewFile {
                        badge("new", color: Color(nsColor: .systemGreen))
                    }
                    if hasSubagentEvents {
                        badge("agent", icon: "arrow.triangle.branch", color: .orange)
                    }
                    diskStateBadge

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isHovering {
                actionButtons(iconOnly: true)
            }

            Text("+\(file.additions)")
                .font(Typography.codeSmall)
                .foregroundStyle(Color(nsColor: .systemGreen))
            Text("\u{2212}\(file.deletions)")
                .font(Typography.codeSmall)
                .foregroundStyle(Color(nsColor: .systemRed))
            Text(file.events.count == 1 ? "1 edit" : "\(file.events.count) edits")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var diskStateBadge: some View {
        switch diskState {
        case .modified:
            badge("modified since", color: .orange)
        case .missing:
            badge("missing", color: Color(nsColor: .systemRed))
        case .clean, .unknown:
            EmptyView()
        }
    }

    private func badge(_ text: String, icon: String? = nil, color: Color) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
            }
            Text(text)
                .font(Typography.micro)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private func actionButtons(iconOnly: Bool) -> some View {
        let missing = diskState == .missing
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: file.path))
        } label: {
            iconOnly ? AnyView(Image(systemName: "arrow.up.forward.app")) : AnyView(Label("Open File", systemImage: "arrow.up.forward.app"))
        }
        .disabled(missing)
        .help(missing ? "File no longer exists on disk" : "Open file")

        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)])
        } label: {
            iconOnly ? AnyView(Image(systemName: "folder")) : AnyView(Label("Reveal in Finder", systemImage: "folder"))
        }
        .disabled(missing)
        .help(missing ? "File no longer exists on disk" : "Reveal in Finder")

        Button {
            copyToPasteboard(FileChangesService.unifiedPatchText(file: file))
            flashCopied()
        } label: {
            iconOnly ? AnyView(Image(systemName: justCopied ? "checkmark" : "doc.on.doc")) : AnyView(Label("Copy Patch", systemImage: "doc.on.doc"))
        }
        .help("Copy all edits as a unified patch")
    }

    private func flashCopied() {
        justCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            justCopied = false
        }
    }
}

// MARK: - Edit event

private struct EditEventView: View {
    let event: FileEditEvent
    let ordinal: Int
    let displayPath: String
    let isFullyShown: Bool
    let onToggleFullyShown: () -> Void
    let onJumpToChat: (String) -> Void

    @State private var justCopied = false

    private static let renderCap = 20

    private var totalHunkLines: Int {
        event.hunks.reduce(0) { $0 + $1.lines.count }
    }

    private var isCapped: Bool {
        totalHunkLines > Self.renderCap && !isFullyShown
    }

    /// Hunks limited to the render cap: (hunk index, hunk, line limit or nil).
    private var visibleHunks: [(index: Int, hunk: PatchHunk, limit: Int?)] {
        guard isCapped else {
            return event.hunks.enumerated().map { ($0.offset, $0.element, nil) }
        }
        var budget = Self.renderCap
        var result: [(Int, PatchHunk, Int?)] = []
        for (index, hunk) in event.hunks.enumerated() {
            guard budget > 0 else { break }
            let take = min(budget, hunk.lines.count)
            result.append((index, hunk, take == hunk.lines.count ? nil : take))
            budget -= take
        }
        return result
    }

    private var kindLabel: String {
        switch event.kind {
        case .edit: return "Edit #\(ordinal)"
        case .writeCreate: return "Write (create)"
        case .writeUpdate: return "Write (update)"
        case .notebookEdit: return "Notebook edit"
        }
    }

    private var kindIcon: String {
        switch event.kind {
        case .edit: return "pencil"
        case .writeCreate, .writeUpdate: return "doc.text.fill"
        case .notebookEdit: return "doc.richtext"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            eventHeader
            if event.hunks.isEmpty {
                Text(emptyCaption)
                    .font(Typography.codeSmall)
                    .foregroundStyle(.tertiary)
            } else {
                if event.isFallbackRendering && event.kind == .notebookEdit {
                    Text("content shown as added (notebook)")
                        .font(Typography.micro)
                        .foregroundStyle(.tertiary)
                }
                ForEach(visibleHunks, id: \.index) { item in
                    HunkView(hunk: item.hunk, lineLimit: item.limit)
                }
                if totalHunkLines > Self.renderCap {
                    Button(isCapped ? "Show all \(totalHunkLines) lines" : "Show less") {
                        onToggleFullyShown()
                    }
                    .buttonStyle(.plain)
                    .font(Typography.caption)
                    .foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private var emptyCaption: String {
        if event.kind == .notebookEdit {
            return "Notebook cell deleted or emptied"
        }
        return "No diff recorded for this edit"
    }

    private var eventHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: kindIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(kindLabel)
                .font(Typography.caption)
            if let time = Self.shortTime(event.timestamp) {
                Text(time)
                    .font(Typography.codeSmall)
                    .foregroundStyle(.tertiary)
            }
            if let agent = event.agentLabel {
                microCapsule(agent, icon: "arrow.triangle.branch", color: .orange)
            }
            if event.replaceAll {
                microCapsule("replace all", color: .secondary)
            }
            if event.userModified {
                microCapsule("user modified", color: .secondary)
            }

            Spacer()

            Text("+\(event.additions)")
                .font(Typography.codeSmall)
                .foregroundStyle(Color(nsColor: .systemGreen))
            Text("\u{2212}\(event.deletions)")
                .font(Typography.codeSmall)
                .foregroundStyle(Color(nsColor: .systemRed))

            Button {
                if let target = event.jumpTargetUuid {
                    onJumpToChat(target)
                }
            } label: {
                Image(systemName: "text.bubble")
            }
            .buttonStyle(.plain)
            .foregroundStyle(event.jumpTargetUuid == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.secondary))
            .disabled(event.jumpTargetUuid == nil)
            .help(event.jumpTargetUuid == nil ? "Spawning call not found in chat" : "Show in chat")

            Button {
                copyToPasteboard(FileChangesService.unifiedPatchText(event: event, displayPath: displayPath))
                justCopied = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    justCopied = false
                }
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy this edit as a unified patch")
        }
    }

    private func microCapsule(_ text: String, icon: String? = nil, color: Color) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
            }
            Text(text)
                .font(Typography.micro)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func shortTime(_ iso: String?) -> String? {
        guard let iso, let date = ISO8601.parse(iso) else { return nil }
        return timeFormatter.string(from: date)
    }
}

// MARK: - Hunk rendering

/// One structuredPatch hunk as colored monospace text. The AttributedString is
/// built once in init (the parsed-once pattern; see the markdown memoization
/// history for why per-body work is banned here). Classic diff red/green by
/// user decision; glyph-run backgrounds are ragged-right by design in v1.
private struct HunkView: View {
    private let header: String
    private let renderedDiff: AttributedString

    init(hunk: PatchHunk, lineLimit: Int? = nil) {
        self.header = "@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@"
        self.renderedDiff = Self.render(hunk: hunk, lineLimit: lineLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header)
                .font(Typography.codeSmall)
                .foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(renderedDiff)
                    .font(Typography.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    private static func render(hunk: PatchHunk, lineLimit: Int?) -> AttributedString {
        let addColor = Color(nsColor: .systemGreen)
        let removeColor = Color(nsColor: .systemRed)
        let lines = lineLimit.map { Array(hunk.lines.prefix($0)) } ?? hunk.lines
        var out = AttributedString()

        for (index, line) in lines.enumerated() {
            if index > 0 {
                out += AttributedString("\n")
            }
            var attr = AttributedString(line.isEmpty ? " " : line)
            switch line.first {
            case "+":
                attr.backgroundColor = addColor.opacity(0.12)
                colorSign(&attr, addColor)
            case "-":
                attr.backgroundColor = removeColor.opacity(0.12)
                colorSign(&attr, removeColor)
            case "\\":
                attr.foregroundColor = .secondary
            default:
                break
            }
            out += attr
        }
        if let lineLimit, lineLimit < hunk.lines.count {
            var more = AttributedString("\n\u{22EF}")
            more.foregroundColor = .secondary
            out += more
        }
        return out
    }

    private static func colorSign(_ attr: inout AttributedString, _ color: Color) {
        guard !attr.characters.isEmpty else { return }
        let start = attr.startIndex
        let next = attr.index(start, offsetByCharacters: 1)
        attr[start..<next].foregroundColor = color
    }
}

// MARK: - Clipboard

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
