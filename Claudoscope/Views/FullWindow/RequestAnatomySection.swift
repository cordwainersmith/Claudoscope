import SwiftUI
import Charts

/// "What fills the context": per-request breakdown of the session's API
/// requests, from the request log Claude Code 2.1.300+ writes. Loaded on
/// demand by `SessionStore.loadRequestAnatomy`.
struct RequestAnatomySection: View {
    @Environment(SessionStore.self) private var store
    let session: ParsedSession

    @State private var showPeak = false
    @State private var loadAttempted = false

    private var locatorKey: String { store.fileChangesKey(for: session) }

    private var anatomy: RequestAnatomy? {
        guard let a = store.requestAnatomy, a.sessionKey == locatorKey else { return nil }
        return a
    }

    var body: some View {
        Group {
            if let anatomy, !anatomy.points.isEmpty {
                content(anatomy)
            } else if anatomy != nil || (loadAttempted && !store.requestAnatomyLoading) {
                Text("A breakdown of what fills the context is recorded by Claude Code 2.1.300 and later.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: locatorKey) {
            await store.loadRequestAnatomy(for: session)
            loadAttempted = true
        }
    }

    private struct Slice: Identifiable {
        let id: String
        let index: Int
        let category: AnatomyCategory
        let tokens: Int
    }

    @ViewBuilder
    private func content(_ anatomy: RequestAnatomy) -> some View {
        let slices = anatomy.points.enumerated().flatMap { index, point in
            AnatomyCategory.allCases.map { category in
                Slice(id: "\(index)-\(category.rawValue)", index: index, category: category, tokens: point.tokens[category] ?? 0)
            }
        }
        let categories = AnatomyCategory.allCases
        let colors = categories.indices.map { Color.chartCategorical[$0 % Color.chartCategorical.count] }

        VStack(alignment: .leading, spacing: 12) {
            Text("What fills the context")
                .font(Typography.body)

            Chart(slices) { slice in
                AreaMark(
                    x: .value("Request", slice.index),
                    y: .value("Tokens", slice.tokens),
                    stacking: .standard
                )
                .foregroundStyle(by: .value("Part", slice.category.label))
            }
            .chartForegroundStyleScale(domain: categories.map(\.label), range: colors)
            .chartXAxisLabel("API request")
            .frame(height: 200)

            if let detail = showPeak ? anatomy.peak : anatomy.latest {
                Picker("", selection: $showPeak) {
                    Text("Latest request").tag(false)
                    Text("Largest request").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                detailCard(detail, colors: colors)
            }

            footnote(anatomy)
        }
    }

    @ViewBuilder
    private func detailCard(_ detail: AnatomyDetail, colors: [Color]) -> some View {
        let total = max(detail.point.totalTokens, 1)
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(formatTokens(detail.point.totalTokens)) tokens")
                    .font(.system(size: 13, weight: .medium))
                ForEach(Array(AnatomyCategory.allCases.enumerated()), id: \.element) { index, category in
                    let tokens = detail.point.tokens[category] ?? 0
                    HStack(spacing: 6) {
                        Circle().fill(colors[index]).frame(width: 8, height: 8)
                        Text(category.label)
                            .font(.system(size: 12))
                            .frame(width: 170, alignment: .leading)
                        Text(formatTokens(tokens))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 60, alignment: .trailing)
                        Text("\(Int((Double(tokens) / Double(total) * 100).rounded()))%")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }

            if !detail.mcpByServer.isEmpty {
                rowList(title: "MCP servers", rows: detail.mcpByServer.map { ("\($0.server) (\($0.toolCount))", $0.tokens) })
            }
            rowList(title: "Largest tool schemas", rows: detail.topTools.map { ($0.name, $0.tokens) })
        }
        .padding(12)
        .background(Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func rowList(title: String, rows: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(formatTokens(row.1))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 260, alignment: .leading)
    }

    private func footnote(_ anatomy: RequestAnatomy) -> some View {
        let deferred = anatomy.latest?.point.deferredToolCount ?? 0
        let estimated = anatomy.points.contains { !$0.isMeasured }
        var parts = ["Totals are each request's real input size; the split is by size, with conversation as the remainder."]
        if deferred > 0 {
            parts.append("\(deferred) more tool\(deferred == 1 ? "" : "s") load on demand through tool search and are not counted.")
        }
        if estimated {
            parts.append("Some requests have no billed reply to measure against and are estimated.")
        }
        return Text(parts.joined(separator: " "))
            .font(Typography.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
