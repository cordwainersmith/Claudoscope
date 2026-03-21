import SwiftUI

enum ToolCategory: String, CaseIterable, Sendable {
    case read
    case write
    case exec
    case other

    var label: String {
        switch self {
        case .read: return "Read"
        case .write: return "Write"
        case .exec: return "Exec"
        case .other: return "Other"
        }
    }
}

func toolCategory(for toolName: String) -> ToolCategory {
    let readTools = ["Read", "Glob", "Grep", "LSP", "WebFetch", "WebSearch"]
    let writeTools = ["Write", "Edit", "NotebookEdit"]
    let execTools = ["Bash", "Agent", "Skill"]

    if readTools.contains(toolName) { return .read }
    if writeTools.contains(toolName) { return .write }
    if execTools.contains(toolName) { return .exec }
    return .other
}

func categoryColor(for toolName: String) -> Color {
    switch toolCategory(for: toolName) {
    case .read:  return Color(red: 0.52, green: 0.72, blue: 0.92) // #85B7EB
    case .write: return Color(red: 0.36, green: 0.79, blue: 0.65) // #5DCAA5
    case .exec:  return Color(red: 0.83, green: 0.66, blue: 0.26) // #D4A843
    case .other: return .secondary
    }
}

func toolIcon(for toolName: String) -> String {
    switch toolName {
    case "Read": return "doc.text"
    case "Write": return "doc.text.fill"
    case "Edit": return "pencil"
    case "Bash": return "terminal"
    case "Grep", "Glob": return "magnifyingglass"
    case "Agent": return "person.2"
    case "WebFetch", "WebSearch": return "globe"
    case "LSP": return "chevron.left.forwardslash.chevron.right"
    case "NotebookEdit": return "doc.richtext"
    case "Skill": return "star"
    default: return "wrench"
    }
}

func primaryArgument(from input: [String: AnyCodableValue], toolName: String) -> String? {
    switch toolName {
    case "Bash": return input["command"]?.stringValue
    case "Read", "Write", "Edit": return input["file_path"]?.stringValue
    case "Grep", "Glob": return input["pattern"]?.stringValue
    case "Agent": return input["description"]?.stringValue
    default: return nil
    }
}
