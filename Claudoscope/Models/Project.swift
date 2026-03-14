import Foundation

struct Project: Identifiable, Sendable {
    let id: String          // encoded directory name
    let name: String        // decoded human-readable name
    let path: String        // full filesystem path
    let sessionCount: Int
}
