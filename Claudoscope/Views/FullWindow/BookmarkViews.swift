import SwiftUI

/// Wraps a chat row with the bookmark affordances: a hover/pinned control in
/// the top-trailing corner, a context menu, a leading accent bar when
/// bookmarked and the note footer beneath the bubble.
struct BookmarkableRow<Content: View>: View {
    let isBookmarked: Bool
    let note: String?
    let onToggle: () -> Void
    let onSaveNote: (String) -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false
    @State private var showingNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            if isBookmarked, let note, !note.isEmpty {
                BookmarkNoteFooter(note: note)
            }
        }
        .padding(.leading, isBookmarked ? 10 : 0)
        .overlay(alignment: .leading) {
            if isBookmarked {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.okabeOrange)
                    .frame(width: 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isHovered || isBookmarked || showingNote {
                BookmarkRowControl(
                    isBookmarked: isBookmarked,
                    note: note,
                    showingNote: $showingNote,
                    onToggle: onToggle,
                    onSaveNote: onSaveNote
                )
                .offset(x: 4, y: -6)
            }
        }
        .contextMenu {
            Button(isBookmarked ? "Remove Bookmark" : "Bookmark", action: onToggle)
            Button(note?.isEmpty == false ? "Edit Note..." : "Add Note...") {
                if !isBookmarked { onToggle() }
                showingNote = true
            }
        }
        .onHover { isHovered = $0 }
    }
}

struct BookmarkRowControl: View {
    let isBookmarked: Bool
    let note: String?
    @Binding var showingNote: Bool
    let onToggle: () -> Void
    let onSaveNote: (String) -> Void

    var body: some View {
        HStack(spacing: 2) {
            if isBookmarked {
                Button {
                    showingNote = true
                } label: {
                    Image(systemName: note?.isEmpty == false ? "note.text" : "note.text.badge.plus")
                        .font(.system(size: 11))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(note?.isEmpty == false ? "Edit note" : "Add note")
                .popover(isPresented: $showingNote, arrowEdge: .top) {
                    BookmarkNotePopover(text: note ?? "") { newNote in
                        onSaveNote(newNote)
                        showingNote = false
                    }
                }
            }
            Button(action: onToggle) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 11))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isBookmarked ? Color.okabeOrange : Color.secondary)
            .help(isBookmarked ? "Remove bookmark" : "Bookmark this turn")
        }
        .padding(2)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
    }
}

struct BookmarkNotePopover: View {
    @State var text: String
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Note")
                .font(.system(size: 12, weight: .semibold))
            TextEditor(text: $text)
                .font(.system(size: 12))
                .frame(width: 280, height: 90)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(AnyShapeStyle(.quaternary), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Save") { onSave(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
        }
        .padding(12)
    }
}

struct BookmarkNoteFooter: View {
    let note: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "note.text")
                .font(.system(size: 10))
                .foregroundStyle(Color.okabeOrange)
                .padding(.top, 2)
            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.okabeOrange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// The pinned "Bookmarks" section at the top of the Sessions sidebar.
struct BookmarksSidebarSection: View {
    let bookmarks: [Bookmark]
    /// Sessions that still have a transcript on disk; a bookmark whose
    /// session is missing stays listed but cannot be opened.
    let knownSessionIds: Set<String>
    let onOpen: (Bookmark) -> Void
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.okabeOrange)
                    Text("Bookmarks")
                        .font(Typography.bodyMedium)
                    Spacer()
                    Text("\(bookmarks.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ForEach(bookmarks) { bookmark in
                    BookmarkSidebarRow(
                        bookmark: bookmark,
                        isAvailable: knownSessionIds.contains(bookmark.sessionId),
                        onOpen: { onOpen(bookmark) }
                    )
                }
            }
            Divider().padding(.vertical, 4)
        }
    }
}

private struct BookmarkSidebarRow: View {
    let bookmark: Bookmark
    let isAvailable: Bool
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: { if isAvailable { onOpen() } }) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(bookmark.sessionTitle)
                        .font(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if !isAvailable {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("Transcript no longer on disk")
                    }
                    Text(formatRelativeDate(Date(timeIntervalSince1970: bookmark.createdAt)))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Text(bookmark.excerpt.isEmpty ? "(no text)" : bookmark.excerpt)
                    .font(Typography.body)
                    .lineLimit(2)
                    .foregroundStyle(isAvailable ? .primary : .secondary)
                if !bookmark.note.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "note.text")
                            .font(.system(size: 9))
                        Text(bookmark.note)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.leading, 18)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered && isAvailable ? Color.primary.opacity(0.04) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
