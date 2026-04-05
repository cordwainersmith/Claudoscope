import Foundation

struct Workspace: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String   // e.g. "Personal", "Work"
    var path: String   // absolute expanded path, e.g. "/Users/ben/.claude"

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}
