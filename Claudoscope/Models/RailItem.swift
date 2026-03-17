import Foundation

enum RailItem: String, CaseIterable, Hashable, Sendable {
    // Primary (above separator)
    case analytics
    case sessions
    case plans
    case timeline

    // Config (below separator)
    case hooks
    case commands
    case mcps
    case skills
    case memory
    case configHealth

    // Pinned bottom
    case settings

    var icon: String {
        switch self {
        case .analytics: return "chart.bar"
        case .sessions:  return "text.line.first.and.arrowtriangle.forward"
        case .plans:     return "doc.text"
        case .timeline:  return "clock.arrow.circlepath"
        case .hooks:     return "arrow.triangle.turn.up.right.diamond"
        case .commands:  return "terminal"
        case .mcps:      return "point.3.connected.trianglepath.dotted"
        case .skills:    return "star"
        case .memory:       return "brain"
        case .configHealth: return "checkmark.shield"
        case .settings:     return "gear"
        }
    }

    var label: String {
        switch self {
        case .analytics: return "Analytics"
        case .sessions:  return "Sessions"
        case .plans:     return "Plans"
        case .timeline:  return "Timeline"
        case .hooks:     return "Hooks"
        case .commands:  return "Commands"
        case .mcps:      return "MCPs"
        case .skills:    return "Skills"
        case .memory:       return "Memory"
        case .configHealth: return "Health"
        case .settings:     return "Settings"
        }
    }

    static var primaryItems: [RailItem] { [.analytics, .sessions, .plans, .timeline] }
    static var configItems: [RailItem] { [.hooks, .commands, .mcps, .skills, .memory, .configHealth] }
}
