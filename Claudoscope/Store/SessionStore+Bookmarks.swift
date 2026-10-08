import Foundation

/// A one-shot request to scroll a session's chat to a record. Keyed by
/// session so the previously selected session, which still renders while
/// the new one loads, cannot consume it.
struct RequestedScrollTarget: Equatable, Sendable {
    let sessionId: String
    let uuid: String
}

extension SessionStore {

    /// Opens `user.sqlite` lazily and fills the bookmark properties. Called
    /// at the top of the scan pipeline so bookmarks exist before the sidebar
    /// renders; safe to call again (re-reads the table).
    func loadBookmarks() async {
        if bookmarkStore == nil {
            bookmarkStore = BookmarkStore.open(at: BookmarkStore.defaultURL())
        }
        guard let store = bookmarkStore else { return }
        do {
            applyBookmarks(try await store.fetchAll())
        } catch {
            NSLog("[Claudoscope] BookmarkStore: fetch failed: %@", error.localizedDescription)
        }
    }

    func isBookmarked(sessionId: String, uuid: String) -> Bool {
        bookmarkedUuids[sessionId]?.contains(uuid) ?? false
    }

    func bookmark(for sessionId: String, uuid: String) -> Bookmark? {
        bookmarks.first { $0.sessionId == sessionId && $0.recordUuid == uuid }
    }

    func bookmarkCount(sessionId: String) -> Int {
        bookmarkCountsBySession[sessionId] ?? 0
    }

    /// Adds or removes the bookmark for `record`. Records without a uuid are
    /// ignored (nothing stable to key on).
    func toggleBookmark(session: ParsedSession, record: ParsedRecordRaw) async {
        guard let uuid = record.uuid, let store = bookmarkStore else { return }
        if let existing = bookmark(for: session.id, uuid: uuid), let id = existing.id {
            await removeBookmark(id: id)
            return
        }
        let now = Date().timeIntervalSince1970
        let title = sessionsByProject[session.projectId]?.first { $0.id == session.id }?.title ?? session.id
        let draft = Bookmark(
            id: nil,
            sessionId: session.id,
            projectId: session.projectId,
            recordUuid: uuid,
            sessionTitle: title,
            excerpt: Bookmark.excerpt(from: record),
            note: "",
            createdAt: now,
            updatedAt: now
        )
        do {
            let inserted = try await store.insert(draft)
            applyBookmarks([inserted] + bookmarks)
        } catch {
            NSLog("[Claudoscope] BookmarkStore: insert failed: %@", error.localizedDescription)
        }
    }

    func updateBookmarkNote(id: Int64, note: String) async {
        guard let store = bookmarkStore else { return }
        do {
            try await store.updateNote(id: id, note: note)
            var updated = bookmarks
            if let i = updated.firstIndex(where: { $0.id == id }) {
                updated[i].note = note
                updated[i].updatedAt = Date().timeIntervalSince1970
            }
            applyBookmarks(updated)
        } catch {
            NSLog("[Claudoscope] BookmarkStore: note update failed: %@", error.localizedDescription)
        }
    }

    func removeBookmark(id: Int64) async {
        guard let store = bookmarkStore else { return }
        do {
            try await store.delete(id: id)
            applyBookmarks(bookmarks.filter { $0.id != id })
        } catch {
            NSLog("[Claudoscope] BookmarkStore: delete failed: %@", error.localizedDescription)
        }
    }

    /// Opens a bookmark's session and scrolls its chat to the turn. The
    /// selection routes through `requestedSelection` so the rail-switch
    /// bookkeeping in FullWindowView loads the session.
    func openBookmark(_ bookmark: Bookmark) {
        requestedScrollTarget = RequestedScrollTarget(sessionId: bookmark.sessionId, uuid: bookmark.recordUuid)
        requestedSelection = RequestedSelection(projectId: bookmark.projectId, sessionId: bookmark.sessionId, tab: "chat")
    }

    private func applyBookmarks(_ all: [Bookmark]) {
        bookmarks = all
        var uuids: [String: Set<String>] = [:]
        var counts: [String: Int] = [:]
        for b in all {
            uuids[b.sessionId, default: []].insert(b.recordUuid)
            counts[b.sessionId, default: 0] += 1
        }
        bookmarkedUuids = uuids
        bookmarkCountsBySession = counts
    }
}
