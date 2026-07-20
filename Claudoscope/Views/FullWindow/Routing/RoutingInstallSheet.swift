import SwiftUI

// MARK: - Install Sheet

/// Confirmation sheet for installing the agent routing stack. Shows per-file
/// preflight status (new / up to date / will overwrite), a disclosure about
/// the built-in Explore shadow, opt-out checkboxes per component, and
/// transitions through review -> installing -> success or error states.
struct RoutingInstallSheet: View {
    let installer: RoutingStackInstaller?
    let claudeDirURL: URL
    var onCompleted: (ActionResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .review
    @State private var errorMessage: String?
    @State private var resultSummary: RoutingInstallResult?
    @State private var preflight: RoutingPreflight?
    @State private var preflightError: String?

    @State private var optionCoreAgents: Bool = true
    @State private var optionSecurityAgents: Bool = true
    @State private var optionPolicyBlock: Bool = true
    @State private var optionSettingsFallbackModel: Bool = true

    enum Phase {
        case review
        case installing
        case success
        case error
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            switch phase {
            case .review:
                reviewBody
            case .installing:
                installingBody
            case .success:
                successBody
            case .error:
                errorBody
            }

            Divider()

            footer
        }
        .frame(width: 540)
        .frame(minHeight: 460)
        .task {
            await loadPreflight()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
            Text("Install Agent Routing Stack")
                .font(Typography.panelTitle)
            Spacer()
        }
        .padding(Spacing.lg)
    }

    // MARK: Review

    private var reviewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section(title: "Components") {
                    componentToggle(text: "Core routing agents (recon, Explore, routine, builder, checker)", isOn: $optionCoreAgents)
                    exploreDisclosure
                    componentToggle(text: "Security pair (security-review, security-build)", isOn: $optionSecurityAgents)
                    componentToggle(text: "Orchestration policy block in CLAUDE.md", isOn: $optionPolicyBlock)
                    if preflight?.hasFallbackModelPayload ?? true {
                        componentToggle(text: "Set settings.json fallbackModel (only if not already set)", isOn: $optionSettingsFallbackModel)
                    }
                }

                if let preflight {
                    section(title: "Agent files") {
                        ForEach(preflight.agentItems) { item in
                            fileStatusRow(item)
                        }
                        Text("Any file that will be overwritten is backed up first.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 16)
                    }
                } else if let preflightError {
                    Text(preflightError)
                        .font(Typography.body)
                        .foregroundStyle(.red)
                }

                section(title: "Backup destination") {
                    bullet("~/.claude/.claudoscope-routing-backup-<yyyyMMdd-HHmmss>/")
                    Text("Existing settings.json, CLAUDE.md, and any overwritten agent files are copied here before any change.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 16)
                }

                section(title: "This installer will never") {
                    bullet("change settings.json's \"model\" key")
                    bullet("add --dangerously-skip-permissions anywhere")
                    bullet("write to your shell profile (.zshrc, etc.)")
                }
            }
            .padding(Spacing.lg)
        }
    }

    private var exploreDisclosure: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("The Core group's Explore agent intentionally takes the place of Claude Code's built-in Explore agent, to pin broad codebase sweeps to a cheaper model. Unchecking Core (or uninstalling later) restores the built-in.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 24)
        .padding(.trailing, 8)
    }

    private func fileStatusRow(_ item: RoutingPreflightItem) -> some View {
        HStack(spacing: 8) {
            Text(item.fileName)
                .font(Typography.code)
                .foregroundStyle(.primary)
            Spacer()
            statusBadge(item.status)
        }
        .padding(.leading, 16)
    }

    private func statusBadge(_ status: RoutingFileStatus) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .new: return ("new", .secondary)
            case .upToDate: return ("up to date", .green)
            case .willOverwriteDiffering: return ("will overwrite \u{2013} differs", .orange)
            }
        }()
        return Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: Installing

    private var installingBody: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Installing routing stack...")
                .font(Typography.bodyMedium)
            Text("This usually takes a second or two.")
                .font(Typography.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(Spacing.xl)
    }

    // MARK: Success

    private var successBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.green)
                    Text("Routing stack installed")
                        .font(Typography.bodyMedium)
                }

                if let result = resultSummary {
                    section(title: "Components applied") {
                        ForEach(result.componentsApplied, id: \.self) { component in
                            bullet(component)
                        }
                    }

                    if !result.overwrittenAgentFiles.isEmpty {
                        section(title: "Files overwritten (backed up first)") {
                            ForEach(result.overwrittenAgentFiles, id: \.self) { name in
                                bullet(name)
                            }
                        }
                    }

                    section(title: "Backup directory") {
                        Text(result.backupPath.path)
                            .font(Typography.codeSmall)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.leading, 16)
                    }

                    section(title: "Marker") {
                        Text(claudeDirURL.appendingPathComponent(RoutingStackInstaller.markerFileName).path)
                            .font(Typography.codeSmall)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.leading, 16)
                    }

                    if !result.warnings.isEmpty {
                        section(title: "Warnings") {
                            ForEach(result.warnings, id: \.self) { warning in
                                bullet(warning)
                            }
                        }
                    }
                }
            }
            .padding(Spacing.lg)
        }
    }

    // MARK: Error

    private var errorBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
                Text("Install failed")
                    .font(Typography.bodyMedium)
            }
            ScrollView {
                Text(errorMessage ?? "Unknown error")
                    .font(Typography.code)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.red.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            }
            .frame(maxHeight: 240)
        }
        .padding(Spacing.lg)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            switch phase {
            case .review:
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") { runInstall() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .installing:
                Button("Cancel") { }
                    .disabled(true)
            case .success:
                Button("Close") {
                    onCompleted(ActionResult(message: "Agent routing stack installed.", isError: false))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            case .error:
                Button("Close") {
                    onCompleted(ActionResult(message: errorMessage ?? "Install failed.", isError: true))
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Retry") { runInstall() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.lg)
    }

    // MARK: Actions

    private func loadPreflight() async {
        guard let installer else {
            await MainActor.run { preflightError = "Installer is not available." }
            return
        }
        do {
            let result = try await installer.preflight()
            await MainActor.run { self.preflight = result }
        } catch {
            await MainActor.run { self.preflightError = String(describing: error) }
        }
    }

    private func runInstall() {
        guard let installer else {
            errorMessage = "Installer is not available."
            phase = .error
            return
        }
        let opts = RoutingInstallOptions(
            coreAgents: optionCoreAgents,
            securityAgents: optionSecurityAgents,
            policyBlock: optionPolicyBlock,
            settingsFallbackModel: optionSettingsFallbackModel
        )
        phase = .installing
        Task {
            do {
                let result = try await installer.install(options: opts)
                await MainActor.run {
                    self.resultSummary = result
                    self.phase = .success
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = String(describing: error)
                    self.phase = .error
                }
            }
        }
    }

    // MARK: Building blocks

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\u{2022}")
                .font(Typography.body)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(Typography.code)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.leading, 4)
    }

    private func componentToggle(text: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(text)
                .font(Typography.body)
        }
        .toggleStyle(.checkbox)
    }
}
