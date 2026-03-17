import SwiftUI

// MARK: - Detail View

struct HealthResultDetailView: View {
    let result: LintResult
    var onNavigateToSession: ((String, String) -> Void)?
    let onBack: () -> Void
    @State private var showUnmasked = false

    private var isSecretResult: Bool {
        result.checkId.rawValue.hasPrefix("SEC")
    }

    private var isSessionResult: Bool {
        result.filePath.hasPrefix("sessions/")
    }

    private var sessionIds: (projectId: String, sessionId: String)? {
        guard isSessionResult else { return nil }
        let parts = result.filePath.split(separator: "/")
        guard parts.count >= 3 else { return nil }
        return (projectId: String(parts[1]), sessionId: String(parts[2]))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Back button
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .medium))
                        Text("Back to overview")
                            .font(Typography.body)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)

                // Severity + display name header
                HStack(spacing: 10) {
                    SeverityBadge(severity: result.severity)

                    Text(displayNameFor(result.checkId))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()
                }
                .padding(.horizontal, 24)

                // File/Session path card
                VStack(alignment: .leading, spacing: 8) {
                    Text(isSessionResult ? "SESSION" : "FILE")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: isSessionResult ? "bubble.left.and.text.bubble.right" : "doc.text")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Text(isSessionResult ? (result.displayPath ?? result.filePath) : result.filePath)
                                .font(.system(size: 13, design: isSessionResult ? .default : .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }

                        if !isSessionResult, let line = result.line {
                            HStack(spacing: 6) {
                                Image(systemName: "number")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text("Line \(line)")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if isSessionResult, let ids = sessionIds, let onNavigateToSession {
                            Button {
                                onNavigateToSession(ids.projectId, ids.sessionId)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.right.circle")
                                        .font(.system(size: 12))
                                    Text("View Session")
                                        .font(Typography.bodyMedium)
                                }
                                .foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
                }
                .padding(.horizontal, 24)

                // Remediation hint card
                if let hint = hintFor(result.checkId) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("REMEDIATION")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)

                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 13))
                                .foregroundStyle(.yellow)

                            Text(hint)
                                .font(Typography.body)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.lg)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 24)
                }

                // Message card
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("DETAILS")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)

                        Spacer()

                        if isSecretResult, result.unmaskedSecret != nil {
                            Button {
                                showUnmasked.toggle()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: showUnmasked ? "eye.slash" : "eye")
                                        .font(.system(size: 12))
                                    Text(showUnmasked ? "Hide" : "Reveal")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text(displayMessage(for: result))
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)

                        // Show unmasked secret value
                        if isSecretResult, showUnmasked, let secret = result.unmaskedSecret {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.shield")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.red)
                                Text(secret)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.red.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.md)
                                    .strokeBorder(Color.red.opacity(0.2), lineWidth: 1)
                            )
                        }

                        // Context lines from the JSONL
                        if let context = result.contextLines, !context.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(context.enumerated()), id: \.offset) { idx, line in
                                    Text(line)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(idx == context.count - 1 ? Color.orange.opacity(0.06) : .clear)

                                    if idx < context.count - 1 {
                                        Divider()
                                            .padding(.horizontal, 10)
                                    }
                                }
                            }
                            .background(AnyShapeStyle(.quaternary).opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.md)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                        }

                        let badges = sessionBadges(for: result)
                        if !badges.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(badges, id: \.text) { badge in
                                    HStack(spacing: 4) {
                                        Circle()
                                            .fill(badge.color)
                                            .frame(width: 6, height: 6)
                                        Text(badge.text)
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(badge.color)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(badge.color.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                                }
                            }
                        }
                    }
                    .padding(Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
                }
                .padding(.horizontal, 24)

                // Legacy fix suggestion (if present and different from hint)
                if let fix = result.fix, fix != hintFor(result.checkId) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("SUGGESTED FIX")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.tertiary)

                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "wrench")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)

                            Text(fix)
                                .font(Typography.body)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                        .padding(Spacing.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.lg)
                                .strokeBorder(.quaternary, lineWidth: 1)
                        )
                    }
                    .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 24)
        }
    }
}
