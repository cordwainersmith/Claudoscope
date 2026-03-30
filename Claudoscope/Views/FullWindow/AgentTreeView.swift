import SwiftUI

struct AgentTreeView: View {
    let session: ParsedSession
    @Environment(SessionStore.self) private var store
    @State private var isLoading = true
    @State private var expandedNodes: Set<String> = []

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading agent tree...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let tree = store.subagentTree {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Header stats
                        HStack(spacing: 12) {
                            treeStat("Agents", "\(1 + tree.children.count)")
                            treeStat("Total Cost", String(format: "$%.2f", totalCost(tree)))
                            treeStat("Tokens", formatTokens(totalTokens(tree)))
                            treeStat("Tool Calls", "\(totalToolCalls(tree))")
                        }

                        Divider()

                        // Tree nodes
                        nodeView(tree, depth: 0, isRoot: true)
                    }
                    .padding(24)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No Subagents")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("This session did not spawn any subagent tasks.")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            await store.loadSubagentTree(sessionId: session.id, projectId: session.projectId)
            isLoading = false
        }
    }

    @ViewBuilder
    private func treeStat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(AnyShapeStyle(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func nodeView(_ node: SubagentNode, depth: Int, isRoot: Bool) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 0) {
                // Node row
                HStack(spacing: 8) {
                    // Connector and icon
                    if !isRoot {
                        Rectangle()
                            .fill(.tertiary)
                            .frame(width: 1, height: 16)
                            .padding(.leading, CGFloat(depth - 1) * 24 + 12)
                    }

                    Image(systemName: isRoot ? "circle.fill" : "arrow.triangle.branch")
                        .font(.system(size: 10))
                        .foregroundStyle(isRoot ? .blue : .orange)
                        .padding(.leading, isRoot ? 0 : 4)

                    Text(node.sessionTitle)
                        .font(.system(size: 13, weight: isRoot ? .semibold : .regular))
                        .lineLimit(1)

                    if let model = node.model {
                        let family = getModelFamily(model)
                        Text(family)
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(modelColor(family).opacity(0.1))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    Text(formatTokens(node.totalInputTokens + node.totalOutputTokens))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)

                    Text(String(format: "$%.2f", node.estimatedCost))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)

                    Text("\(node.toolCallCount) tools")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 6)
                .padding(.leading, isRoot ? 0 : CGFloat(depth) * 24)

                // Children
                ForEach(node.children) { child in
                    Divider().padding(.leading, CGFloat(depth + 1) * 24)
                    nodeView(child, depth: depth + 1, isRoot: false)
                }
            }
        )
    }

    private func totalCost(_ node: SubagentNode) -> Double {
        node.estimatedCost + node.children.reduce(0) { $0 + totalCost($1) }
    }

    private func totalTokens(_ node: SubagentNode) -> Int {
        let own = node.totalInputTokens + node.totalOutputTokens
        return own + node.children.reduce(0) { $0 + totalTokens($1) }
    }

    private func totalToolCalls(_ node: SubagentNode) -> Int {
        node.toolCallCount + node.children.reduce(0) { $0 + totalToolCalls($1) }
    }

    private func modelColor(_ family: String) -> Color {
        switch family {
        case "opus": return .purple
        case "sonnet": return .blue
        case "haiku": return .green
        default: return .gray
        }
    }
}
