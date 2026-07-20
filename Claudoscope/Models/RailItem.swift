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
    case agents
    case plugins
    case memory
    case canon
    case configHealth
    case hardening
    case agentRouting

    // Pinned bottom
    case settings

    var icon: String {
        switch self {
        case .analytics: return "chart.bar"
        case .sessions:  return "text.line.first.and.arrowtriangle.forward"
        case .tools:     return "wrench.and.screwdriver"
        case .plans:     return "doc.text"
        case .timeline:  return "clock.arrow.circlepath"
        case .cowork:    return "checklist"
        case .hooks:     return "arrow.triangle.turn.up.right.diamond"
        case .commands:  return "terminal"
        case .mcps:      return "point.3.connected.trianglepath.dotted"
        case .skills:    return "star"
        case .agents:    return "person.2"
        case .plugins:   return "puzzlepiece.extension"
        case .memory:       return "brain"
        case .canon:        return "building.columns"
        case .configHealth: return "checkmark.shield"
        case .hardening:    return "lock.shield"
        case .agentRouting: return "arrow.triangle.branch"
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
        case .agents:    return "Agents"
        case .plugins:   return "Plugins"
        case .memory:       return "Memory"
        case .canon:        return "Canon"
        case .configHealth: return "Health"
        case .hardening:    return "Hardening"
        case .agentRouting: return "Routing"
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
    static var configItems: [RailItem] { [.hooks, .commands, .mcps, .skills, .agents, .plugins, .memory, .canon, .configHealth, .hardening, .agentRouting] }
}
