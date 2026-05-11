import Foundation

enum RailItem: String, CaseIterable, Hashable, Sendable {
    // Primary (above separator)
    case analytics
    case sessions
    case tools
    case plans
    case timeline
    case cowork

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
        case .tools:     return "wrench.and.screwdriver"
        case .plans:     return "doc.text"
        case .timeline:  return "clock.arrow.circlepath"
        case .cowork:    return "sparkles"
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
        case .tools:     return "Tools"
        case .plans:     return "Plans"
        case .timeline:  return "Timeline"
        case .cowork:    return "Cowork"
        case .hooks:     return "Hooks"
        case .commands:  return "Commands"
        case .mcps:      return "MCPs"
        case .skills:    return "Skills"
        case .memory:       return "Memory"
        case .configHealth: return "Health"
        case .settings:     return "Settings"
        }
    }

    /// True for rails that should only appear when a corresponding data
    /// source is available. Both RailView (sidebar) and CommandPaletteOverlay
    /// (command-K) consult this so a hidden rail is never offered anywhere.
    var requiresCoworkAvailability: Bool {
        self == .cowork
    }

    static var primaryItems: [RailItem] { [.analytics, .sessions, .tools, .plans, .timeline, .cowork] }
    static var configItems: [RailItem] { [.hooks, .commands, .mcps, .skills, .memory, .configHealth] }
}
