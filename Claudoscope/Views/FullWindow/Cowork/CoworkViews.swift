import SwiftUI
import AppKit

// MARK: - Sidebar

struct CoworkSidebarContent: View {
    let filterText: String
    let sessions: [CoworkSession]
    let parsedSessionsByID: [String: ParsedSession]
    let pricingTable: [String: ModelPricing]
    @Binding var selectedSessionId: String?

    private var filtered: [CoworkSession] {
        guard !filterText.isEmpty else { return sessions }
        return sessions.filter { s in
            s.displayTitle.localizedCaseInsensitiveContains(filterText) ||
            (s.processName ?? "").localizedCaseInsensitiveContains(filterText) ||
            (s.initialMessage ?? "").localizedCaseInsensitiveContains(filterText) ||
            (s.cwd ?? "").localizedCaseInsensitiveContains(filterText)
        }
    }

    var body: some View {
        if filtered.isEmpty {
            SidebarEmptyStateView(icon: "sparkles", text: "No Cowork sessions found")
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(filtered) { session in
                    CoworkRow(
                        session: session,
                        cost: parsedSessionsByID[session.id].map {
                            CoworkStats.totalCost(records: $0.records, pricingTable: pricingTable)
                        },
                        isSelected: selectedSessionId == session.id
                    ) {
                        selectedSessionId = session.id
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

private struct CoworkRow: View {
    let session: CoworkSession
    let cost: Double?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle)
                    .font(Typography.bodyMedium)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? .white : .primary)

                HStack(spacing: 4) {
                    Text(session.projectId.prefix(8) + "…")
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Text("·")
                    Text(formatRelative(session.effectiveLastActivity))
                        .font(.system(size: 11))
                        .lineLimit(1)
                    if let model = session.model {
                        Text("·")
                        Text(modelShort(model))
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    Spacer()
                    if let cost {
                        Text(formatCost(cost))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func formatRelative(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    private func modelShort(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "-20251001", with: "")
    }

    private func formatCost(_ cost: Double) -> String {
        cost < 0.01 ? "<$0.01" : String(format: "$%.2f", cost)
    }
}

// MARK: - Main panel

struct CoworkMainPanelView: View {
    let sessions: [CoworkSession]
    let parsedSessionsByID: [String: ParsedSession]
    let pricingTable: [String: ModelPricing]
    @Binding var selectedSessionId: String?

    private var selectedSession: CoworkSession? {
        guard let id = selectedSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    var body: some View {
        if let session = selectedSession {
            CoworkSessionDetail(
                session: session,
                parsedSession: parsedSessionsByID[session.id],
                pricingTable: pricingTable
            )
        } else if sessions.isEmpty {
            EmptyStateView(
                icon: "sparkles",
                title: "No Cowork sessions",
                message: "Run a task in Claude Cowork (Claude desktop app). Sessions will appear here automatically."
            )
        } else if let id = selectedSessionId, sessions.first(where: { $0.id == id }) == nil {
            EmptyStateView(
                icon: "sparkles",
                title: "Session no longer exists",
                message: "The selected Cowork session was removed. Pick another from the sidebar."
            )
        } else {
            EmptyStateView(
                icon: "sparkles",
                title: "Select a Cowork session",
                message: "Choose a session from the sidebar to view metadata, stats, and the transcript."
            )
        }
    }
}

private struct CoworkSessionDetail: View {
    let session: CoworkSession
    let parsedSession: ParsedSession?
    let pricingTable: [String: ModelPricing]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CoworkHeader(session: session)
                CoworkMetadataCard(session: session)
                if let parsed = parsedSession {
                    CoworkStatsCard(records: parsed.records, pricingTable: pricingTable)
                } else if session.transcriptURL != nil {
                    Text("Loading transcript…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                if !session.detectedFiles.isEmpty {
                    CoworkGeneratedFilesList(files: session.detectedFiles)
                }
                if let parsed = parsedSession, !parsed.records.isEmpty {
                    Divider().padding(.horizontal, 16)
                    Text("Transcript")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    ChatView(session: parsed)
                        .frame(minHeight: 400)
                }
            }
            .padding(.vertical, 16)
        }
    }
}

private struct CoworkHeader: View {
    let session: CoworkSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            Text(session.displayTitle)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(2)
            if session.isArchived {
                Text("archived")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }
}

private struct CoworkMetadataCard: View {
    let session: CoworkSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Process name", value: session.processName)
            row("Cowork session", value: session.sessionId)
            row("Inner CLI session", value: session.cliSessionId)
            row("Project", value: session.projectId)
            row("Model", value: session.model)
            cwdRow
            row("Created", value: format(session.createdAt))
            row("Last activity", value: format(session.effectiveLastActivity))
            if !session.slashCommandNames.isEmpty {
                row("Slash commands", value: session.slashCommandNames.joined(separator: ", "))
            }
            row("Initial prompt", value: session.initialMessage, multiline: true)
            HStack {
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([session.metadataURL])
                } label: {
                    Label("Reveal underlying JSON", systemImage: "doc.badge.arrow.up")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func row(_ label: String, value: String?, multiline: Bool = false) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Text(value)
                    .font(.system(size: 12, design: multiline ? .default : .monospaced))
                    .lineLimit(multiline ? nil : 1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var cwdRow: some View {
        if let cwd = session.cwd, !cwd.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Text("Working directory")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 130, alignment: .leading)
                Button {
                    let url = URL(fileURLWithPath: cwd)
                    if FileManager.default.fileExists(atPath: cwd) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(cwd)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                Spacer()
            }
        }
    }

    private func format(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct CoworkStatsCard: View {
    let records: [ParsedRecordRaw]
    let pricingTable: [String: ModelPricing]

    private var totals: CoworkStats.Totals {
        CoworkStats.totals(records: records, pricingTable: pricingTable)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                stat("Messages", value: "\(totals.messageCount)")
                stat("Input", value: formatTokens(totals.input))
                stat("Output", value: formatTokens(totals.output))
                stat("Cache read", value: formatTokens(totals.cacheRead))
                stat("Cost", value: totals.hasUnknownModel ? "—" : String(format: "$%.2f", totals.cost))
            }
            if totals.hasUnknownModel {
                Label("model not priced — at least one model is missing from the pricing table",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if totals.modelBreakdown.count > 1 {
                Divider()
                ForEach(totals.modelBreakdown, id: \.model) { row in
                    HStack(spacing: 8) {
                        Text(row.model)
                            .font(.system(size: 11, design: .monospaced))
                        Text("\(row.messageCount) msgs")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if row.isUnknown {
                            Text("not priced")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.orange)
                        } else {
                            Text(String(format: "$%.2f", row.cost))
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func stat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
        }
    }
}

private struct CoworkGeneratedFilesList: View {
    let files: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Generated files")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(files, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer()
                    if FileManager.default.fileExists(atPath: path) {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        } label: {
                            Text("Reveal")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Text("missing")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Stats helper

enum CoworkStats {
    struct Totals {
        var messageCount: Int = 0
        var input: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        var cacheCreation: Int = 0
        var cost: Double = 0
        var hasUnknownModel: Bool = false
        var modelBreakdown: [ModelRow] = []
    }

    struct ModelRow {
        let model: String
        let messageCount: Int
        let cost: Double
        let isUnknown: Bool
    }

    /// Walk an in-memory record list once, summing tokens and cost per
    /// (deduped) billable assistant message. Mirrors SessionParser's billing
    /// rule: bill records where either (a) stop_reason is set or (b) no record
    /// in the file with this msg.id ever has stop_reason (orphan/aborted
    /// stream). Cowork's audit.jsonl frequently omits stop_reason entirely,
    /// so the orphan path is what produces non-zero totals here.
    static func totals(records: [ParsedRecordRaw], pricingTable: [String: ModelPricing]) -> Totals {
        var t = Totals()
        var seenMessageIds = Set<String>()
        var perModel: [String: (msgs: Int, cost: Double, isUnknown: Bool)] = [:]

        // First pass: collect msg.ids of records that have stop_reason.
        var stopReasonIds = Set<String>()
        for record in records where record.type == .assistant {
            if let msg = record.message, msg.stopReason != nil, let id = msg.id {
                stopReasonIds.insert(id)
            }
        }

        for record in records where record.type == .assistant {
            guard let usage = record.message?.usage else { continue }
            let msgId = record.message?.id
            let isOrphan = msgId.map { !stopReasonIds.contains($0) } ?? true
            let isBillable = record.message?.stopReason != nil || isOrphan
            guard isBillable else { continue }
            if let msgId {
                if seenMessageIds.contains(msgId) { continue }
                seenMessageIds.insert(msgId)
            }
            let input = usage.inputTokens ?? 0
            let output = usage.outputTokens ?? 0
            let cacheRead = usage.cacheReadInputTokens ?? 0
            let cacheCreate = usage.cacheCreationInputTokens ?? 0
            let cache5m = usage.cacheCreation?.ephemeral5mInputTokens ?? cacheCreate
            let cache1h = usage.cacheCreation?.ephemeral1hInputTokens ?? 0

            t.messageCount += 1
            t.input += input
            t.output += output
            t.cacheRead += cacheRead
            t.cacheCreation += cacheCreate

            let model = record.message?.model ?? "unknown"
            let pricing = getModelPricing(model, table: pricingTable)
            let isUnknown = pricing.isUnknown
            if isUnknown { t.hasUnknownModel = true }

            // Fast mode: same rule as SessionParser.parseMetadata, so the rail,
            // Analytics, and the popover summaries all bill identically.
            let speed = usage.speed
            let isFastMode = speed != nil && speed != "standard"
            let speedMultiplier = isFastMode ? fastModeRateMultiplier : 1.0

            let msgCost = isUnknown ? 0 : estimateCostFromTokens(
                model: model,
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheCreation5mTokens: cache5m,
                cacheCreation1hTokens: cache1h,
                table: pricingTable,
                speedMultiplier: speedMultiplier
            )
            t.cost += msgCost

            var entry = perModel[model] ?? (msgs: 0, cost: 0, isUnknown: isUnknown)
            entry.msgs += 1
            entry.cost += msgCost
            entry.isUnknown = isUnknown
            perModel[model] = entry
        }

        t.modelBreakdown = perModel
            .map { ModelRow(model: $0.key, messageCount: $0.value.msgs, cost: $0.value.cost, isUnknown: $0.value.isUnknown) }
            .sorted { $0.cost > $1.cost }
        return t
    }

    static func totalCost(records: [ParsedRecordRaw], pricingTable: [String: ModelPricing]) -> Double {
        totals(records: records, pricingTable: pricingTable).cost
    }
}
