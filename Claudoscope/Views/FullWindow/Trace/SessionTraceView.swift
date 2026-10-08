import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The session on a time axis, laid out like a player: a status display on
/// top, the lanes filling the panel, transport controls at the bottom.
/// Hover for a readout, click to jump into the chat, drag to measure a range,
/// replay to watch it unfold, and export a share card.
struct SessionTraceView: View {
    let session: ParsedSession
    /// Called with a record uuid; the host switches to the Chat tab and scrolls.
    let onJumpToChat: (String) -> Void

    @Environment(SessionStore.self) private var store
    @AppStorage("traceCollapsesGaps") private var collapsesGaps = true

    @State private var trace: SessionTrace?
    @State private var isBuilding = true
    @State private var hover: TraceHit?
    @State private var hoverPoint: CGPoint = .zero
    @State private var dragAnchor: Double?
    @State private var selection: ClosedRange<Double>?
    @State private var playhead: Double?
    @State private var isPlaying = false
    @State private var replaySpeed: TraceReplaySpeed = .x300
    @State private var replayTask: Task<Void, Never>?
    @State private var shareNotice: String?
    @FocusState private var isFocused: Bool

    private var axis: TraceTimeAxis? {
        trace.map { TraceTimeAxis(trace: $0, collapsesGaps: collapsesGaps) }
    }

    var body: some View {
        Group {
            if isBuilding {
                ProgressView("Building trace…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let trace, let axis {
                VStack(spacing: 0) {
                    TraceStatusDisplay(moment: currentMoment(trace: trace, axis: axis))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    Divider()
                    GeometryReader { geo in
                        let layout = TraceLayout.make(
                            trace: trace,
                            width: geo.size.width - 24,
                            height: geo.size.height - 20
                        )
                        plot(trace: trace, axis: axis, layout: layout)
                            .frame(width: geo.size.width - 24, height: layout.height)
                            .padding(.horizontal, 12)
                            .padding(.top, 12)
                    }
                    Divider()
                    transportBar(trace: trace, axis: axis)
                }
            } else {
                EmptyStateView(
                    icon: "waveform.path.ecg",
                    title: "Nothing to trace",
                    message: "This session has no timestamped turns yet."
                )
            }
        }
        .task(id: session.id) { await build() }
        .onDisappear { stopReplay() }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.leftArrow) { stepTurn(-1); return .handled }
        .onKeyPress(.rightArrow) { stepTurn(1); return .handled }
        .onKeyPress(.space) { toggleReplay(); return .handled }
        .onKeyPress(.escape) {
            if selection != nil { selection = nil; return .handled }
            if playhead != nil { stopReplay(); playhead = nil; return .handled }
            return .ignored
        }
    }

    // MARK: - Build

    private func build() async {
        isBuilding = true
        let session = self.session
        let table = store.pricingTable
        let built = await Task.detached(priority: .userInitiated) { () -> SessionTrace? in
            let blocked = ObservabilityAnalyzer.extractBlockedActions(from: extractToolCalls(from: session))
            return SessionTrace.build(for: session, blockedToolUseIds: Set(blocked.map(\.id)), pricingTable: table)
        }.value
        trace = built
        isBuilding = false
    }

    // MARK: - Status

    /// What the display shows, by priority: a share notice, a measured range,
    /// the hovered moment, the replay playhead, else the whole session.
    private func currentMoment(trace: SessionTrace, axis: TraceTimeAxis) -> TraceMoment {
        if let shareNotice {
            return .notice(shareNotice)
        }
        if let selection {
            return .range(
                from: axis.date(atFraction: selection.lowerBound),
                to: axis.date(atFraction: selection.upperBound),
                trace: trace
            )
        }
        if let hover, dragAnchor == nil {
            let date = axis.date(atFraction: hover.fraction)
            return .moment(at: date, mode: "Hover", trace: trace, detail: hover.title.isEmpty ? nil : hover.title)
        }
        if let playhead {
            let date = axis.date(atFraction: playhead)
            return .moment(at: date, mode: isPlaying ? "Replay" : "Paused", trace: trace, detail: nil)
        }
        return .session(trace)
    }

    // MARK: - Plot

    private func plot(trace: SessionTrace, axis: TraceTimeAxis, layout: TraceLayout) -> some View {
        let renderer = TraceRenderer(trace: trace, axis: axis, layout: layout, palette: .panel, reveal: playhead)
        let hits = TraceHit.targets(trace: trace, renderer: renderer)
        return Canvas { context, _ in
            renderer.draw(in: &context)
        }
        .overlay { plotOverlay(renderer: renderer) }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                hoverPoint = point
                hover = TraceHit.nearest(to: point, in: hits, layout: layout)
            case .ended:
                hover = nil
            }
        }
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { value in
                    let f0 = fraction(forX: value.startLocation.x, layout: layout)
                    let f1 = fraction(forX: value.location.x, layout: layout)
                    dragAnchor = f0
                    selection = min(f0, f1)...max(f0, f1)
                }
                .onEnded { _ in
                    dragAnchor = nil
                    if let selection, selection.upperBound - selection.lowerBound < 0.002 {
                        self.selection = nil
                    }
                }
        )
        .onTapGesture { point in
            isFocused = true
            if let axisRow = layout.row(.axis), axisRow.rect.contains(point) {
                pauseReplay()
                playhead = fraction(forX: point.x, layout: layout)
            } else if let hit = TraceHit.nearest(to: point, in: hits, layout: layout), let uuid = hit.uuid {
                onJumpToChat(uuid)
            } else if selection != nil {
                selection = nil
            }
        }
    }

    private func fraction(forX x: CGFloat, layout: TraceLayout) -> Double {
        Double(min(max((x - layout.plotX) / layout.plotWidth, 0), 1))
    }

    @ViewBuilder
    private func plotOverlay(renderer: TraceRenderer) -> some View {
        let layout = renderer.layout
        let plotRect = CGRect(
            x: layout.plotX, y: layout.plotTop,
            width: layout.plotWidth, height: layout.plotBottom - layout.plotTop
        )
        ZStack(alignment: .topLeading) {
            if let selection {
                let x1 = renderer.x(fraction: selection.lowerBound)
                let x2 = renderer.x(fraction: selection.upperBound)
                Rectangle()
                    .fill(Color.okabeBlue.opacity(0.12))
                    .overlay(Rectangle().strokeBorder(Color.okabeBlue.opacity(0.5), lineWidth: 1))
                    .frame(width: max(x2 - x1, 1), height: plotRect.height)
                    .offset(x: x1, y: plotRect.minY)
                    .allowsHitTesting(false)
            }
            if let playhead {
                let px = renderer.x(fraction: playhead)
                Rectangle()
                    .fill(Color.primary.opacity(0.7))
                    .frame(width: 1.5, height: plotRect.height)
                    .offset(x: px - 0.75, y: plotRect.minY)
                    .allowsHitTesting(false)
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.primary)
                    .offset(x: px - 4.5, y: plotRect.minY - 2)
                    .allowsHitTesting(false)
            }
            if let hover, dragAnchor == nil {
                let px = renderer.x(fraction: hover.fraction)
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1, height: plotRect.height)
                    .offset(x: px, y: plotRect.minY)
                    .allowsHitTesting(false)
                if let laneRect = hover.laneRect {
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.6), lineWidth: 1)
                        .frame(width: 10, height: 10)
                        .offset(x: px - 5, y: laneRect.midY - 5)
                        .allowsHitTesting(false)
                }
                if !hover.title.isEmpty {
                    tooltip(for: hover, at: px, containerWidth: layout.plotMaxX + TraceLayout.rightPad)
                }
            }
        }
    }

    private func tooltip(for hit: TraceHit, at px: CGFloat, containerWidth: CGFloat) -> some View {
        let text = Text(hit.title)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.middle)
        return HStack(spacing: 6) {
            if let turn = hit.turnNumber {
                Text("Turn \(turn)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            text
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        .frame(maxWidth: 360, alignment: .leading)
        .fixedSize()
        .offset(x: min(max(px - 40, 4), max(containerWidth - 240, 4)), y: max(hoverPoint.y - 30, 0))
        .allowsHitTesting(false)
    }

    // MARK: - Transport

    private func transportBar(trace: SessionTrace, axis: TraceTimeAxis) -> some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { playhead ?? 0 },
                    set: { newValue in
                        pauseReplay()
                        playhead = newValue
                    }
                ),
                in: 0...1
            )
            .controlSize(.mini)
            .help("Scrub through the session")

            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    transportButton("backward.end.fill", help: "Previous turn (←)") { stepTurn(-1) }
                    Button {
                        toggleReplay()
                    } label: {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 34, height: 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isPlaying ? Color.okabeOrange : Color.okabeBlue)
                    .help(isPlaying ? "Pause replay (space)" : "Replay the session (space)")
                    transportButton("forward.end.fill", help: "Next turn (→)") { stepTurn(1) }
                    transportButton("stop.fill", help: "Stop and show everything (Esc)") {
                        stopReplay()
                        playhead = nil
                    }
                    .disabled(playhead == nil)
                }

                Picker("", selection: $replaySpeed) {
                    ForEach(TraceReplaySpeed.allCases, id: \.self) { speed in
                        Text(speed.label).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 250)
                .help("Replay speed")

                Spacer()

                Text(positionLabel(trace: trace, axis: axis))
                    .font(.system(size: 11, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle("Collapse idle", isOn: $collapsesGaps)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 11))
                    .disabled(trace.gaps.isEmpty)
                    .help("Shrink idle stretches longer than five minutes to a marked break")

                Menu {
                    Button("Save image…") { saveShareCard(trace: trace) }
                    Button("Copy image") { copyShareCard(trace: trace) }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Export a share card: stats and the trace, no transcript text")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func transportButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 22)
        }
        .buttonStyle(.bordered)
        .help(help)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private func positionLabel(trace: SessionTrace, axis: TraceTimeAxis) -> String {
        let total = TraceRenderer.longDuration(trace.activeDuration)
        guard let playhead else { return "\(trace.userTurns.count) turns · \(total) active" }
        let date = axis.date(atFraction: playhead)
        let elapsed = axis.virtualOffset(of: date)
        let turn = trace.turn(at: date)?.turnNumber ?? 0
        return "\(Self.clockFormatter.string(from: date)) · turn \(turn)/\(trace.userTurns.count) · \(TraceRenderer.longDuration(elapsed)) of \(total)"
    }

    // MARK: - Replay

    private func toggleReplay() {
        if isPlaying { pauseReplay() } else { startReplay() }
    }

    private func startReplay() {
        guard let axis else { return }
        if playhead == nil || (playhead ?? 0) >= 1 { playhead = 0 }
        isPlaying = true
        replayTask?.cancel()
        let duration = axis.virtualDuration
        replayTask = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard !Task.isCancelled, isPlaying else { return }
                let now = Date()
                let seconds = now.timeIntervalSince(last) * replaySpeed.multiplier(virtualDuration: duration)
                last = now
                let next = min((playhead ?? 0) + seconds / duration, 1)
                playhead = next
                if next >= 1 { isPlaying = false; return }
            }
        }
    }

    private func pauseReplay() {
        isPlaying = false
        replayTask?.cancel()
        replayTask = nil
    }

    private func stopReplay() {
        pauseReplay()
    }

    private func stepTurn(_ direction: Int) {
        guard let trace, let axis, !trace.userTurns.isEmpty else { return }
        pauseReplay()
        let fractions = trace.userTurns.map { axis.fraction(of: $0.time) }
        let current = playhead ?? (direction > 0 ? -1 : 2)
        let next: Double?
        if direction > 0 {
            next = fractions.first { $0 > current + 0.0001 }
        } else {
            next = fractions.last { $0 < current - 0.0001 }
        }
        if let next { playhead = next } else if direction > 0 { playhead = 1 }
    }

    // MARK: - Share card

    @MainActor
    private func renderShareCard(trace: SessionTrace) -> NSImage? {
        let card = TraceShareCard(
            trace: trace,
            projectName: decodeProjectName(session.projectId),
            collapsesGaps: collapsesGaps
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        return renderer.nsImage
    }

    private func copyShareCard(trace: SessionTrace) {
        guard let image = renderShareCard(trace: trace) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        flashNotice("Share card copied")
    }

    private func saveShareCard(trace: SessionTrace) {
        guard let image = renderShareCard(trace: trace),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "claudoscope-trace-\(session.id.prefix(8)).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try png.write(to: url)
            flashNotice("Saved \(url.lastPathComponent)")
        } catch {
            flashNotice("Could not save: \(error.localizedDescription)")
        }
    }

    private func flashNotice(_ text: String) {
        shareNotice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if shareNotice == text { shareNotice = nil }
        }
    }
}

// MARK: - Status display

/// One frame of the status display: a mode tag, a headline, a clock and the
/// figures that matter at that moment.
struct TraceMoment: Equatable {
    let mode: String
    let headline: String
    let subline: String?
    let clock: String
    let clockCaption: String
    let contextUtilization: Double?
    let cost: Double
    let costCaption: String
    let turnText: String
    let toolText: String

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    static func session(_ trace: SessionTrace) -> TraceMoment {
        var subline = "\(trace.userTurns.count) turns"
        if !trace.gaps.isEmpty { subline += ", \(trace.gaps.count) idle break\(trace.gaps.count == 1 ? "" : "s")" }
        if !trace.compactions.isEmpty { subline += ", \(trace.compactions.count) compaction\(trace.compactions.count == 1 ? "" : "s")" }
        subline += " · hover, click to open in Chat, drag to measure, space to replay"
        return TraceMoment(
            mode: "Session",
            headline: trace.userTurns.first?.label ?? "Session",
            subline: subline,
            clock: TraceRenderer.longDuration(trace.activeDuration),
            clockCaption: "active · \(dayFormatter.string(from: trace.start))",
            contextUtilization: trace.contextPoints.last?.utilization,
            cost: trace.totalCost,
            costCaption: "total",
            turnText: "\(trace.userTurns.count)",
            toolText: "\(trace.toolCalls.count)"
        )
    }

    static func moment(at date: Date, mode: String, trace: SessionTrace, detail: String?) -> TraceMoment {
        let turn = trace.turn(at: date)
        let toolsSoFar = trace.toolCalls.filter { $0.time <= date }.count
        return TraceMoment(
            mode: mode,
            headline: detail ?? turn?.label ?? "Before the first prompt",
            subline: turn.map { "Turn \($0.turnNumber) of \(trace.userTurns.count)" + (detail != nil ? " · \($0.label)" : "") },
            clock: clockFormatter.string(from: date),
            clockCaption: dayFormatter.string(from: date),
            contextUtilization: trace.contextUtilization(at: date),
            cost: trace.cost(at: date),
            costCaption: "so far",
            turnText: turn.map { "\($0.turnNumber)/\(trace.userTurns.count)" } ?? "0/\(trace.userTurns.count)",
            toolText: "\(toolsSoFar)/\(trace.toolCalls.count)"
        )
    }

    static func range(from: Date, to: Date, trace: SessionTrace) -> TraceMoment {
        let turns = trace.userTurns.filter { (from...to).contains($0.time) }.count
        let calls = trace.toolCalls.filter { (from...to).contains($0.time) }
        let failed = calls.filter { $0.isError || $0.isBlocked }.count
        var subline = "\(turns) turn\(turns == 1 ? "" : "s"), \(calls.count) tool call\(calls.count == 1 ? "" : "s")"
        if failed > 0 { subline += ", \(failed) failed or blocked" }
        subline += " · Esc clears"
        return TraceMoment(
            mode: "Selected",
            headline: "\(clockFormatter.string(from: from)) to \(clockFormatter.string(from: to))",
            subline: subline,
            clock: TraceRenderer.longDuration(to.timeIntervalSince(from)),
            clockCaption: "selected",
            contextUtilization: trace.contextUtilization(at: to),
            cost: trace.cost(at: to) - trace.cost(at: from),
            costCaption: "in range",
            turnText: "\(turns)",
            toolText: "\(calls.count)"
        )
    }

    static func notice(_ text: String) -> TraceMoment {
        TraceMoment(
            mode: "Share", headline: text, subline: nil, clock: "", clockCaption: "",
            contextUtilization: nil, cost: 0, costCaption: "", turnText: "", toolText: ""
        )
    }
}

struct TraceStatusDisplay: View {
    let moment: TraceMoment

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text(moment.mode.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(moment.mode == "Replay" ? Color.okabeOrange : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        (moment.mode == "Replay" ? Color.okabeOrange : Color.primary).opacity(0.1),
                        in: RoundedRectangle(cornerRadius: 3)
                    )
                Text(moment.headline)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subline = moment.subline {
                    Text(subline)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !moment.clock.isEmpty {
                VStack(spacing: 1) {
                    Text(moment.clock)
                        .font(.system(size: 26, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text(moment.clockCaption)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(minWidth: 150)

                HStack(spacing: 18) {
                    figure("Turn", moment.turnText)
                    figure("Tools", moment.toolText)
                    contextFigure
                    figure(moment.costCaption, formatCost(moment.cost))
                }
            }
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(minWidth: 54, alignment: .trailing)
    }

    private var contextFigure: some View {
        let utilization = moment.contextUtilization ?? 0
        let percent = Int((utilization * 100).rounded())
        return VStack(alignment: .trailing, spacing: 2) {
            Text("CONTEXT")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(utilization > 0.85 ? Color.okabeVermillion : Color.okabeOrange)
                            .frame(width: max(geo.size.width * min(utilization, 1), 2))
                    }
                }
                .frame(width: 48, height: 6)
                Text(moment.contextUtilization == nil ? "—" : "\(percent)%")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }
}

// MARK: - Replay speed

enum TraceReplaySpeed: CaseIterable, Hashable {
    case x60, x300, x1200, fit

    var label: String {
        switch self {
        case .x60: return "60×"
        case .x300: return "300×"
        case .x1200: return "1200×"
        case .fit: return "20 s"
        }
    }

    /// Session seconds advanced per wall-clock second.
    func multiplier(virtualDuration: TimeInterval) -> Double {
        switch self {
        case .x60: return 60
        case .x300: return 300
        case .x1200: return 1200
        case .fit: return max(virtualDuration / 20, 1)
        }
    }
}

// MARK: - Hit testing

/// One hoverable mark on the plot. Built once per layout; hover picks the
/// nearest by x, preferring the lane under the cursor.
struct TraceHit: Equatable {
    let fraction: Double
    let laneRect: CGRect?
    let turnNumber: Int?
    let title: String
    let detail: String?
    let uuid: String?

    private static let slop: CGFloat = 6

    static func targets(trace: SessionTrace, renderer: TraceRenderer) -> [TraceHit] {
        let axis = renderer.axis
        let layout = renderer.layout
        var hits: [TraceHit] = []
        let youRect = layout.row(.you)?.rect
        for turn in trace.userTurns {
            hits.append(TraceHit(
                fraction: axis.fraction(of: turn.time), laneRect: youRect, turnNumber: turn.turnNumber,
                title: turn.label, detail: "prompt", uuid: turn.uuid
            ))
        }
        let claudeRect = layout.row(.claude)?.rect
        for span in trace.claudeSpans {
            hits.append(TraceHit(
                fraction: axis.fraction(of: span.start), laneRect: claudeRect, turnNumber: span.turnNumber,
                title: "Claude worked \(TraceRenderer.longDuration(span.end.timeIntervalSince(span.start)))",
                detail: "\(span.toolCallCount) tool calls this turn", uuid: span.uuid
            ))
        }
        for call in trace.toolCalls {
            let rect = layout.row(.tool(call.category))?.rect
            var title = call.label
            if call.isBlocked { title = "Blocked: " + title } else if call.isError { title = "Error: " + title }
            hits.append(TraceHit(
                fraction: axis.fraction(of: call.time), laneRect: rect,
                turnNumber: trace.turn(at: call.time)?.turnNumber, title: title, detail: nil, uuid: call.uuid
            ))
        }
        if let agentsRow = layout.row(.agents) {
            let pitch = TraceLayout.agentRowPitch(in: agentsRow.rect, trace: trace)
            for span in trace.agentSpans {
                let shownRow = min(span.row, TraceLayout.maxAgentRows - 1)
                let y = agentsRow.rect.minY + 4 + CGFloat(shownRow) * pitch
                let rect = CGRect(x: agentsRow.rect.minX, y: y, width: agentsRow.rect.width, height: pitch)
                let ran = span.end.map { "ran \(TraceRenderer.longDuration($0.timeIntervalSince(span.start)))" } ?? "still running"
                hits.append(TraceHit(
                    fraction: axis.fraction(of: span.start), laneRect: rect,
                    turnNumber: trace.turn(at: span.start)?.turnNumber,
                    title: "Agent: \(span.label)", detail: ran, uuid: span.uuid
                ))
            }
        }
        let contextRect = layout.row(.context)?.rect
        for compaction in trace.compactions {
            hits.append(TraceHit(
                fraction: axis.fraction(of: compaction.time), laneRect: contextRect,
                turnNumber: trace.turn(at: compaction.time)?.turnNumber,
                title: "Compaction", detail: "context was summarized here", uuid: compaction.uuid
            ))
        }
        return hits
    }

    /// Nearest hit by x within the slop. A hit in the lane under the cursor
    /// wins over a closer one in another lane; with no lane match, the
    /// cursor's x becomes a plain moment readout.
    static func nearest(to point: CGPoint, in hits: [TraceHit], layout: TraceLayout) -> TraceHit? {
        guard point.x >= layout.plotX - slop, point.x <= layout.plotMaxX + slop else { return nil }
        var inLane: (TraceHit, CGFloat)?
        var anywhere: (TraceHit, CGFloat)?
        for hit in hits {
            let hx = layout.plotX + CGFloat(hit.fraction) * layout.plotWidth
            let distance = abs(hx - point.x)
            guard distance <= slop else { continue }
            if let rect = hit.laneRect, rect.minY - 2 <= point.y, point.y <= rect.maxY + 2 {
                if inLane == nil || distance < inLane!.1 { inLane = (hit, distance) }
            }
            if anywhere == nil || distance < anywhere!.1 { anywhere = (hit, distance) }
        }
        if let inLane { return inLane.0 }
        if let anywhere { return anywhere.0 }
        let fraction = Double(min(max((point.x - layout.plotX) / layout.plotWidth, 0), 1))
        return TraceHit(fraction: fraction, laneRect: nil, turnNumber: nil, title: "", detail: nil, uuid: nil)
    }
}
