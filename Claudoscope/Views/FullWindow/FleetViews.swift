import SwiftUI

// Fleet is a full-bleed control-tower board: always dark, monospaced, and
// deliberately outside the dashboard style guide so it reads as a live ops
// surface rather than another list/detail rail.

// MARK: - Palette

enum Tower {
    static let bg = Color(red: 0.047, green: 0.051, blue: 0.063)
    static let panel = Color.white.opacity(0.035)
    static let panelHover = Color.white.opacity(0.06)
    static let line = Color.white.opacity(0.08)
    static let text = Color(white: 0.93)
    static let dim = Color(white: 0.58)
    static let faint = Color(white: 0.36)

    static let amber = Color(red: 1.0, green: 0.72, blue: 0.22)
    static let red = Color(red: 1.0, green: 0.34, blue: 0.31)
    static let green = Color(red: 0.36, green: 0.9, blue: 0.6)
    static let cyan = Color(red: 0.38, green: 0.8, blue: 1.0)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func color(_ state: FleetState) -> Color {
        switch state {
        case .blockedOnPermission, .failed: return red
        case .waitingOnUser: return amber
        case .working: return green
        case .idle: return cyan
        case .done: return dim
        }
    }

    static func code(_ state: FleetState) -> String {
        switch state {
        case .blockedOnPermission: return "BLOCKED"
        case .waitingOnUser: return "WAITING"
        case .working: return "WORKING"
        case .idle: return "PARKED"
        case .failed: return "FAILED"
        case .done: return "LANDED"
        }
    }

    /// Stopwatch text: 42s, 04:12, 1:04:12, 2d 3h.
    static func clock(from start: Date, to end: Date) -> String {
        let s = max(0, Int(end.timeIntervalSince(start)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return String(format: "%02d:%02d", s / 60, s % 60) }
        if s < 86400 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }
}

// MARK: - Board

struct FleetBoardView: View {
    @Environment(SessionStore.self) private var store
    @Environment(SessionNotificationService.self) private var sessionNotificationService
    var onNavigateToSession: ((String, String, String?) -> Void)?

    @State private var selection: String?
    @State private var query = ""
    @State private var hazardOnly = false

    private var visible: [FleetAgent] {
        store.fleetAgents.filter { agent in
            if hazardOnly && !agent.isBypass { return false }
            guard !query.isEmpty else { return true }
            return [agent.summary.title, agent.projectName, agent.branchLabel ?? ""]
                .joined(separator: " ")
                .localizedCaseInsensitiveContains(query)
        }
    }

    private var needsYou: [FleetAgent] {
        let ids = Set(visible.map(\.id))
        return store.attentionQueue.filter { ids.contains($0.id) }
    }

    private var working: [FleetAgent] {
        visible.filter { $0.state == .working }
    }

    /// Live processes sitting idle: nothing to answer, but still holding a
    /// terminal and a warm (or cooling) prompt cache.
    private var parked: [FleetAgent] {
        visible.filter { !$0.state.needsAttention && $0.isLive && $0.state != .working }
    }

    private var landed: [FleetAgent] {
        visible.filter { !$0.state.needsAttention && !$0.isLive && $0.state != .working }
    }

    private var selectedAgent: FleetAgent? {
        selection.flatMap { id in store.fleetAgents.first { $0.id == id } }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Tower.bg

            if store.fleetAgents.isEmpty {
                emptyBoard
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        header
                        TelemetryStrip(agents: store.fleetAgents)
                        if !sessionNotificationService.config.masterEnabled {
                            hooksNotice
                        }
                        if !needsYou.isEmpty {
                            lane(title: "NEEDS YOU", count: needsYou.count, tint: Tower.amber) {
                                VStack(spacing: 10) {
                                    ForEach(Array(needsYou.enumerated()), id: \.element.id) { index, agent in
                                        NeedsYouTile(agent: agent, isFirst: index == 0,
                                                     onInspect: { selection = agent.id },
                                                     onOpen: { open(agent) })
                                    }
                                }
                            }
                        }
                        if !working.isEmpty {
                            lane(title: "WORKING", count: working.count, tint: Tower.green) {
                                tileGrid(working)
                            }
                        }
                        if !parked.isEmpty {
                            lane(title: "PARKED", count: parked.count, tint: Tower.cyan) {
                                tileGrid(parked)
                            }
                        }
                        if !landed.isEmpty {
                            lane(title: "LANDED · 24H", count: landed.count, tint: Tower.faint) {
                                VStack(spacing: 0) {
                                    ForEach(landed) { agent in
                                        LandedRow(agent: agent, isSelected: selection == agent.id) {
                                            selection = agent.id
                                        }
                                    }
                                }
                                .background(Tower.panel)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        if visible.isEmpty {
                            Text("NO MATCHES")
                                .font(Tower.mono(12, .semibold))
                                .tracking(2)
                                .foregroundStyle(Tower.faint)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        }
                    }
                    .padding(32)
                }
            }

            if let agent = selectedAgent {
                Color.black.opacity(0.35)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = nil }
                    .transition(.opacity)
                FleetInspector(agent: agent, onClose: { selection = nil }, onOpen: { open(agent) })
                    .frame(width: 400)
                    .transition(.move(edge: .trailing))
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.28), value: selection)
        .animation(.easeInOut(duration: 0.2), value: store.fleetAgents.map(\.state))
    }

    private func tileGrid(_ agents: [FleetAgent]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 270, maximum: 420), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 12) {
            ForEach(agents) { agent in
                InFlightTile(agent: agent, isSelected: selection == agent.id) {
                    selection = agent.id
                }
            }
        }
    }

    private func open(_ agent: FleetAgent) {
        selection = nil
        onNavigateToSession?(agent.summary.projectId, agent.summary.id, nil)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("FLEET CONTROL")
                    .font(Tower.mono(11, .semibold))
                    .tracking(3)
                    .foregroundStyle(Tower.faint)
                Spacer()
                controls
            }
            HStack(alignment: .bottom, spacing: 24) {
                headline
                Spacer(minLength: 16)
                HStack(spacing: 22) {
                    counter("LIVE", store.fleetAgents.filter(\.isLive).count, Tower.text)
                    counter("WORKING", store.fleetAgents.filter { $0.state == .working }.count, Tower.green)
                    counter("WAITING", store.attentionQueue.count, Tower.amber)
                    counter("SKIP PERMS", store.fleetAgents.filter { $0.isBypass && $0.isLive }.count, Tower.red)
                }
            }
        }
    }

    @ViewBuilder
    private var headline: some View {
        let waiting = store.attentionQueue.count
        let working = store.fleetAgents.filter { $0.state == .working }.count
        if waiting > 0 {
            (Text("\(waiting) ").foregroundColor(Tower.amber)
             + Text(waiting == 1 ? "agent needs you" : "agents need you").foregroundColor(Tower.text))
                .font(.system(size: 34, weight: .bold, design: .monospaced))
        } else if working > 0 {
            (Text("All clear. ").foregroundColor(Tower.text)
             + Text("\(working) working").foregroundColor(Tower.text))
                .font(.system(size: 34, weight: .bold, design: .monospaced))
        } else {
            Text("All quiet.")
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .foregroundStyle(Tower.text)
        }
    }

    private func counter(_ label: String, _ value: Int, _ tint: Color) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(value)")
                .font(Tower.mono(26, .semibold))
                .foregroundStyle(value > 0 ? tint : Tower.faint)
                .contentTransition(.numericText())
            Text(label)
                .font(Tower.mono(9, .medium))
                .tracking(1.5)
                .foregroundStyle(Tower.faint)
        }
    }

    private var controls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Tower.faint)
                TextField("filter", text: $query)
                    .textFieldStyle(.plain)
                    .font(Tower.mono(12))
                    .frame(width: 140)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Tower.panel)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Tower.line))

            Button {
                hazardOnly.toggle()
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(hazardOnly ? Tower.bg : Tower.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(hazardOnly ? Tower.red : Tower.panel)
                    .clipShape(Capsule())
                    .overlay(Capsule().strokeBorder(Tower.red.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .help(hazardOnly ? "Show every agent" : "Only agents that skipped permissions")
        }
    }

    private var hooksNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(Tower.amber)
            Text("Permission prompts are invisible without the notification hooks.")
                .font(Tower.mono(12))
                .foregroundStyle(Tower.dim)
            Spacer()
            Button("ENABLE") { store.requestedRail = .settings }
                .buttonStyle(TowerButtonStyle(tint: Tower.amber, filled: false))
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tower.amber.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }

    private func lane<Content: View>(title: String, count: Int, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Rectangle().fill(tint).frame(width: 14, height: 2)
                Text(title)
                    .font(Tower.mono(11, .bold))
                    .tracking(2.5)
                    .foregroundStyle(tint)
                Text("\(count)")
                    .font(Tower.mono(11))
                    .foregroundStyle(Tower.faint)
                Rectangle().fill(Tower.line).frame(height: 1)
            }
            content()
        }
    }

    private var emptyBoard: some View {
        VStack(spacing: 14) {
            ZStack {
                ForEach(1..<4) { ring in
                    Circle()
                        .strokeBorder(Tower.line, lineWidth: 1)
                        .frame(width: CGFloat(ring) * 70, height: CGFloat(ring) * 70)
                }
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 26))
                    .foregroundStyle(Tower.faint)
                    .symbolEffect(.pulse)
            }
            .frame(height: 220)
            Text("NO TRAFFIC")
                .font(Tower.mono(16, .bold))
                .tracking(4)
                .foregroundStyle(Tower.dim)
            Text("Running Claude Code sessions and anything from the last 24 hours land here.")
                .font(Tower.mono(12))
                .foregroundStyle(Tower.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Needs-you tile

private struct NeedsYouTile: View {
    let agent: FleetAgent
    let isFirst: Bool
    let onInspect: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    private var tint: Color { Tower.color(agent.state) }

    private var reason: String {
        if case .waitingOnUser(let reason) = agent.state { return reason }
        return "Permission prompt"
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tint).frame(width: 5)

            HStack(alignment: .center, spacing: 20) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Tower.clock(from: agent.since, to: context.date))
                            .font(Tower.mono(30, .bold))
                            .foregroundStyle(tint)
                            .monospacedDigit()
                        Text("WAITING")
                            .font(Tower.mono(9, .semibold))
                            .tracking(2)
                            .foregroundStyle(Tower.faint)
                    }
                }
                .frame(width: 150, alignment: .leading)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: agent.state == .blockedOnPermission ? "lock.fill" : "hand.raised.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(tint)
                            .symbolEffect(.pulse)
                        Text(reason)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Tower.text)
                            .lineLimit(1)
                    }
                    Text(agent.displayPrompt)
                        .font(.system(size: 12))
                        .foregroundStyle(Tower.dim)
                        .lineLimit(1)
                    AgentMeta(agent: agent)
                    HStack(spacing: 16) {
                        LastActionLine(turn: agent.summary.latestTurn)
                        ContextGauge(turn: agent.summary.latestTurn)
                            .frame(width: 190)
                        CacheCountdown(turn: agent.summary.latestTurn)
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Button("OPEN", action: onOpen)
                        .buttonStyle(TowerButtonStyle(tint: Tower.dim, filled: false))
                        .disabled(agent.summary.isCowork)
                    if !agent.summary.isCowork {
                        jumpButton
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .background(tint.opacity(hovering ? 0.12 : 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.35)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onInspect)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var jumpButton: some View {
        let button = Button {
            TerminalFocuser.focus(matchingTitle: agent.focusNeedle)
        } label: {
            HStack(spacing: 6) {
                Text("JUMP")
                if isFirst { Text("⌘⏎").opacity(0.6) }
            }
        }
        .buttonStyle(TowerButtonStyle(tint: tint, filled: true))
        .disabled(!agent.isLive)
        .help(agent.isLive ? "Bring the terminal tab titled \(agent.focusNeedle) forward" : "The process is no longer running")

        if isFirst {
            button.keyboardShortcut(.return, modifiers: .command)
        } else {
            button
        }
    }
}

// MARK: - In-flight tile

private struct InFlightTile: View {
    let agent: FleetAgent
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    private var tint: Color { Tower.color(agent.state) }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // Live sessions wear their state color across the top:
                // green while working, cyan while parked.
                if agent.isLive || agent.state == .working {
                    Rectangle()
                        .fill(tint)
                        .frame(height: 3)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: agent.state == .working ? "waveform" : "pause.circle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(tint)
                            .symbolEffect(.variableColor.iterative, isActive: agent.state == .working)
                        Text(Tower.code(agent.state))
                            .font(Tower.mono(10, .bold))
                            .tracking(1.5)
                            .foregroundStyle(tint)
                        if agent.isBackgroundJob {
                            Text("BG")
                                .font(Tower.mono(9, .bold))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Tower.faint))
                                .foregroundStyle(Tower.dim)
                        }
                        BypassTag(agent: agent)
                        Spacer()
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack(spacing: 8) {
                                Text(Tower.clock(from: agent.since, to: context.date))
                                    .font(Tower.mono(12, .semibold))
                                    .foregroundStyle(tint)
                                Text("age \(Tower.clock(from: agent.startedAt, to: context.date))")
                                    .font(Tower.mono(10))
                                    .foregroundStyle(Tower.faint)
                            }
                            .monospacedDigit()
                            .help("Time in this state, then time since the session started")
                        }
                    }

                    Text(agent.projectName)
                        .font(Tower.mono(18, .bold))
                        .foregroundStyle(Tower.text)
                        .lineLimit(1)

                    Text(agent.displayPrompt)
                        .font(.system(size: 12))
                        .foregroundStyle(Tower.dim)
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                        .help(agent.summary.title)

                    // Always rendered, with placeholders, so every tile in a
                    // grid row has the same height.
                    LastActionLine(turn: agent.summary.latestTurn)
                    ContextGauge(turn: agent.summary.latestTurn)
                    StatChips(agent: agent)

                    Rectangle().fill(Tower.line).frame(height: 1)

                    HStack(spacing: 10) {
                        AgentMeta(agent: agent, showsProject: false)
                        Spacer(minLength: 4)
                        Text(formatCost(agent.summary.estimatedCost))
                            .font(Tower.mono(12, .semibold))
                            .foregroundStyle(Tower.amber)
                    }
                }
                .padding(14)
            }
            .background(hovering || isSelected ? Tower.panelHover : Tower.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? tint : Tower.line, lineWidth: isSelected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Landed row

private struct LandedRow: View {
    let agent: FleetAgent
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                Text(Tower.code(agent.state))
                    .font(Tower.mono(10, .bold))
                    .tracking(1)
                    .foregroundStyle(Tower.color(agent.state).opacity(0.8))
                    .frame(width: 64, alignment: .leading)
                Text(agent.projectName)
                    .font(Tower.mono(12, .semibold))
                    .foregroundStyle(Tower.dim)
                    .frame(width: 160, alignment: .leading)
                    .lineLimit(1)
                Text(agent.displayPrompt)
                    .font(.system(size: 12))
                    .foregroundStyle(Tower.faint)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if agent.isBypass {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(Tower.red.opacity(0.5))
                        .help("Ran with skipped permissions")
                }
                Text(agent.since, format: .relative(presentation: .numeric))
                    .font(Tower.mono(11))
                    .foregroundStyle(Tower.faint)
                    .frame(width: 110, alignment: .trailing)
                Text(formatCost(agent.summary.estimatedCost))
                    .font(Tower.mono(11))
                    .foregroundStyle(Tower.amber.opacity(0.7))
                    .frame(width: 70, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovering || isSelected ? Tower.panelHover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(Tower.line).frame(height: 1) }
    }
}

// MARK: - Inspector

private struct FleetInspector: View {
    let agent: FleetAgent
    let onClose: () -> Void
    let onOpen: () -> Void

    private var summary: SessionSummary { agent.summary }
    private var tint: Color { Tower.color(agent.state) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Tower.code(agent.state))
                    .font(Tower.mono(11, .bold))
                    .tracking(2)
                    .foregroundStyle(tint)
                Text("since \(agent.since, format: .relative(presentation: .named))")
                    .font(Tower.mono(11))
                    .foregroundStyle(Tower.faint)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Tower.dim)
                        .frame(width: 24, height: 24)
                        .background(Tower.panel)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            if agent.isBypass {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("RAN WITH SKIPPED PERMISSIONS")
                        .font(Tower.mono(10, .bold))
                        .tracking(1)
                }
                .foregroundStyle(Tower.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Tower.red.opacity(0.1))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(agent.projectName)
                            .font(Tower.mono(22, .bold))
                            .foregroundStyle(Tower.text)
                        Text(summary.title)
                            .font(.system(size: 13))
                            .foregroundStyle(Tower.dim)
                            .textSelection(.enabled)
                        if let prompt = summary.latestTurn?.lastPrompt {
                            Text("\u{201C}\(prompt)\u{201D}")
                                .font(.system(size: 12))
                                .italic()
                                .foregroundStyle(Tower.faint)
                                .textSelection(.enabled)
                        }
                    }

                    if case .waitingOnUser(let reason) = agent.state {
                        callout(reason)
                    } else if agent.state == .blockedOnPermission {
                        callout("Waiting for a permission decision.")
                    }

                    HStack(spacing: 8) {
                        if !summary.isCowork {
                            Button("FOCUS TERMINAL") {
                                TerminalFocuser.focus(matchingTitle: agent.focusNeedle)
                            }
                            .buttonStyle(TowerButtonStyle(tint: tint, filled: true))
                            .disabled(!agent.isLive)
                            .help(agent.isLive ? "Looks for a terminal tab titled \(agent.focusNeedle)" : "The process is no longer running")
                        }
                        Button("OPEN SESSION", action: onOpen)
                            .buttonStyle(TowerButtonStyle(tint: Tower.dim, filled: false))
                            .disabled(summary.isCowork)
                    }

                    section("AGENT") {
                        row("branch", agent.branchLabel)
                        row("worktree", summary.worktreeName)
                        row("pr", summary.prNumber.map { "#\($0)" })
                        row("model", summary.primaryModel.map { getModelFamily($0) })
                        row("mode", summary.lastPermissionMode)
                        row("last", formatRelativeTime(summary.lastTimestamp))
                        row("tokens", formatTokens(summary.totalInputTokens + summary.totalOutputTokens))
                        row("cost", formatCost(summary.estimatedCost))
                        row("burn", agent.burnRatePerHour(now: Date()).map { "\(formatCost($0))/hr avg" })
                        row("cache", agent.cacheHitRate.map { "\(Int(($0 * 100).rounded()))% of prompt tokens" })
                        row("compact", summary.compactionCount > 0 ? "\(summary.compactionCount)" : nil)
                        row("errors", summary.observability.errorClassifications.isEmpty ? nil
                            : summary.observability.errorClassifications.map(\.rawValue).joined(separator: ", "))
                    }

                    if let turn = summary.latestTurn {
                        section("LATEST TURN") {
                            if let used = turn.contextTokens, let window = turn.contextWindowTokens {
                                row("context", "\(formatTokens(used)) / \(formatTokens(window))")
                            }
                            row("tool", turn.toolName)
                            row("target", turn.toolTarget)
                            row("at", turn.toolTimestamp.map(formatRelativeTime))
                            if agent.isLive, turn.cacheTTLSeconds != nil {
                                HStack(spacing: 12) {
                                    Text("cache")
                                        .font(Tower.mono(11))
                                        .foregroundStyle(Tower.faint)
                                        .frame(width: 70, alignment: .leading)
                                    CacheCountdown(turn: turn)
                                }
                            }
                        }
                    }

                    if let reg = agent.registry {
                        section("PROCESS") {
                            row("pid", "\(reg.pid)")
                            row("status", reg.status)
                            row("kind", reg.kind)
                            row("version", reg.version)
                            row("cwd", reg.cwd)
                            row("job", reg.jobId)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(red: 0.07, green: 0.075, blue: 0.09))
        .overlay(alignment: .leading) { Rectangle().fill(tint.opacity(0.6)).frame(width: 2) }
        .shadow(color: .black.opacity(0.5), radius: 24, x: -8)
    }

    private func callout(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(tint)
                .symbolEffect(.pulse)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Tower.text)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Tower.mono(10, .bold))
                .tracking(2)
                .foregroundStyle(Tower.faint)
            VStack(alignment: .leading, spacing: 6) { content() }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .font(Tower.mono(11))
                    .foregroundStyle(Tower.faint)
                    .frame(width: 70, alignment: .leading)
                Text(value)
                    .font(Tower.mono(12))
                    .foregroundStyle(Tower.text)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Shared pieces

private struct AgentMeta: View {
    let agent: FleetAgent
    var showsProject = true

    var body: some View {
        HStack(spacing: 10) {
            if showsProject {
                Text(agent.projectName)
                    .foregroundStyle(Tower.text.opacity(0.8))
            }
            if let branch = agent.branchLabel {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .labelStyle(TightLabelStyle())
            }
            if let model = agent.summary.primaryModel {
                Text(getModelFamily(model))
            }
        }
        .font(Tower.mono(11))
        .foregroundStyle(Tower.faint)
        .lineLimit(1)
    }
}

/// Context occupancy of the latest turn as a meter. The fill steps to amber
/// then red as the session nears compaction; the text always states the value.
private struct ContextGauge: View {
    let turn: LatestTurn?

    /// Worst of two bands: share of the window (what triggers compaction) and
    /// absolute size (what a 1M window hides: cost and recall degrade long
    /// before it fills).
    private var tint: Color {
        let u = turn?.contextUtilization ?? 0
        let used = turn?.contextTokens ?? 0
        if u >= 0.85 || used >= 600_000 { return Tower.red }
        if u >= 0.6 || used >= 300_000 { return Tower.amber }
        return Tower.cyan
    }

    var body: some View {
        if let turn, let utilization = turn.contextUtilization, let used = turn.contextTokens,
           let window = turn.contextWindowTokens {
            HStack(spacing: 8) {
                Text("CTX")
                    .font(Tower.mono(9, .bold))
                    .foregroundStyle(Tower.faint)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Tower.line)
                        Capsule().fill(tint)
                            .frame(width: max(4, geo.size.width * min(1, utilization)))
                    }
                }
                .frame(height: 4)
                Text("\(Int((utilization * 100).rounded()))%")
                    .font(Tower.mono(10, .semibold))
                    .foregroundStyle(Tower.text)
                    .fixedSize()
                Text("\(formatTokens(used))/\(formatTokens(window))")
                    .font(Tower.mono(10))
                    .foregroundStyle(Tower.dim)
                    .fixedSize()
            }
            .help("Context in use at the latest turn: \(Int((utilization * 100).rounded()))% of the window")
        } else {
            HStack(spacing: 8) {
                Text("CTX")
                    .font(Tower.mono(9, .bold))
                    .foregroundStyle(Tower.faint)
                Capsule().fill(Tower.line).frame(height: 4)
                Text("—")
                    .font(Tower.mono(10))
                    .foregroundStyle(Tower.faint)
            }
            .help("No billed turn recorded yet")
        }
    }
}

private struct LastActionLine: View {
    let turn: LatestTurn?

    var body: some View {
        if let turn, let name = turn.toolName {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Tower.faint)
                Text(name)
                    .font(Tower.mono(11, .semibold))
                    .foregroundStyle(Tower.text)
                if let target = turn.toolTarget {
                    Text(target)
                        .font(Tower.mono(11))
                        .foregroundStyle(Tower.dim)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let ts = turn.toolTimestamp {
                    Text(formatRelativeTime(ts))
                        .font(Tower.mono(10))
                        .foregroundStyle(Tower.faint)
                        .fixedSize()
                }
            }
            .lineLimit(1)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 8, weight: .bold))
                Text("no tool calls yet")
                    .font(Tower.mono(11))
            }
            .foregroundStyle(Tower.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Burn rate, cache hit, compactions and errors as terse mono chips. Chips
/// only appear when they carry a value.
private struct StatChips: View {
    let agent: FleetAgent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                if let rate = agent.burnRatePerHour(now: context.date) {
                    chip("\(formatCost(rate))/hr", help: "Average spend rate since the session started")
                }
                if agent.isLive && agent.state != .working {
                    CacheCountdown(turn: agent.summary.latestTurn)
                }
                if let hit = agent.cacheHitRate {
                    chip("cache \(Int((hit * 100).rounded()))%", help: "Share of prompt tokens read from cache",
                         warn: hit < 0.5)
                }
                if agent.summary.compactionCount > 0 {
                    chip("⟳\(agent.summary.compactionCount)", help: "Context compactions",
                         warn: agent.summary.compactionCount > 1)
                }
                let errors = agent.summary.observability.errorClassifications
                if !errors.isEmpty {
                    chip("⚠ \(errors.count)", help: errors.map(\.rawValue).joined(separator: ", "), alert: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(_ text: String, help: String, warn: Bool = false, alert: Bool = false) -> some View {
        let tint = alert ? Tower.red : (warn ? Tower.amber : Tower.dim)
        return Text(text)
            .font(Tower.mono(10, .medium))
            .foregroundStyle(alert || warn ? tint : Tower.dim)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.35)))
            .help(help)
    }
}

/// Board-wide numbers: today's spend, the live burn rate, and a 24h
/// concurrency sparkline.
private struct TelemetryStrip: View {
    let agents: [FleetAgent]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let burn = agents.filter(\.isLive).compactMap { $0.burnRatePerHour(now: now) }.reduce(0, +)
            let hourly = FleetStateEngine.hourlyConcurrency(agents, now: now)
            HStack(alignment: .bottom, spacing: 28) {
                metric("TODAY", formatCost(FleetStateEngine.spendOnDay(agents, now: now)),
                       help: "Spend by the sessions on this board on today's date")
                metric("LIVE BURN", "\(formatCost(burn))/hr",
                       help: "Sum of the live sessions' average spend rates")
                VStack(alignment: .leading, spacing: 4) {
                    ConcurrencySparkline(counts: hourly, now: now)
                        .frame(height: 30)
                    HStack {
                        Text("ACTIVE · 24H")
                        Spacer()
                        Text("peak \(hourly.max() ?? 0)")
                    }
                    .font(Tower.mono(9, .medium))
                    .tracking(1.5)
                    .foregroundStyle(Tower.faint)
                }
                .frame(maxWidth: 360)
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Tower.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tower.line))
        }
    }

    private func metric(_ label: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Tower.mono(20, .semibold))
                .foregroundStyle(Tower.text)
                .contentTransition(.numericText())
            Text(label)
                .font(Tower.mono(9, .medium))
                .tracking(1.5)
                .foregroundStyle(Tower.faint)
        }
        .help(help)
    }
}

private struct ConcurrencySparkline: View {
    let counts: [Int]
    let now: Date

    var body: some View {
        let peak = max(1, counts.max() ?? 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(counts.enumerated()), id: \.offset) { index, count in
                let hoursAgo = counts.count - index
                UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                    .fill(count > 0 ? Tower.text.opacity(index == counts.count - 1 ? 0.8 : 0.4) : Tower.line)
                    .frame(maxWidth: .infinity)
                    .frame(height: count > 0 ? max(3, 30 * CGFloat(count) / CGFloat(peak)) : 2)
                    .help("\(count) active, \(hoursAgo)h to \(hoursAgo - 1)h ago")
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}

/// Red tag while the session is in bypass mode right now; a faint shield if
/// it bypassed earlier and has since left the mode.
private struct BypassTag: View {
    let agent: FleetAgent

    var body: some View {
        if agent.summary.lastPermissionMode == "bypassPermissions" {
            Text("BYPASS")
                .font(Tower.mono(9, .bold))
                .tracking(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .foregroundStyle(Tower.red)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Tower.red.opacity(0.6)))
                .help("Running with skipped permissions")
        } else if agent.isBypass {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 10))
                .foregroundStyle(Tower.red.opacity(0.5))
                .help("Ran with skipped permissions earlier in this session")
        }
    }
}

/// Time left on the prompt cache since the last billed turn. Answering after
/// it expires means paying to write the whole context back into cache.
private struct CacheCountdown: View {
    let turn: LatestTurn?

    var body: some View {
        if let turn, let ttl = turn.cacheTTLSeconds,
           let last = turn.turnTimestamp.flatMap(ISO8601.parse) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = Int(last.addingTimeInterval(TimeInterval(ttl)).timeIntervalSince(context.date))
                let tint = remaining <= 0 ? Tower.faint : (remaining < 60 ? Tower.red : Tower.amber)
                HStack(spacing: 4) {
                    Image(systemName: remaining > 0 ? "timer" : "snowflake")
                        .font(.system(size: 9, weight: .semibold))
                    Text(remaining > 0
                         ? "cache \(Tower.clock(from: context.date, to: context.date.addingTimeInterval(TimeInterval(remaining))))"
                         : "cache cold")
                        .font(Tower.mono(10, .medium))
                        .monospacedDigit()
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.4)))
                .fixedSize()
                .help(remaining > 0
                      ? "Prompt cache (\(ttl == 3600 ? "1h" : "5m") tier) expires after this; answering later re-caches the whole context"
                      : "Prompt cache expired; the next turn re-writes the context")
            }
        }
    }
}

private extension FleetAgent {
    /// The last prompt reads better than a generated title or id prefix.
    var displayPrompt: String {
        summary.latestTurn?.lastPrompt ?? summary.title
    }
}

struct TowerButtonStyle: ButtonStyle {
    let tint: Color
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Tower.mono(11, .bold))
            .tracking(1)
            .foregroundStyle(filled ? Tower.bg : tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(filled ? tint : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(tint.opacity(filled ? 0 : 0.5)))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
    }
}
