import SwiftUI

// MARK: - Install Sheet

/// Confirmation sheet for installing the hardening baseline. Shows the planned
/// changes (files created, files modified, backup destination), per-layer
/// opt-out checkboxes, and transitions through idle -> in-progress -> success
/// or error states.
struct HardeningInstallSheet: View {
    let installer: HardeningInstaller?
    let claudeDirURL: URL
    var onCompleted: (ActionResult) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .review
    @State private var errorMessage: String?
    @State private var resultSummary: HardeningInstallResult?

    @State private var optionLayer1Permissions: Bool = true
    @State private var optionLayer1Sandbox: Bool = true
    @State private var optionLayer2Hooks: Bool = true
    @State private var optionLayer3AutoMode: Bool = true
    @State private var optionLayer4Governance: Bool = true
    @State private var optionSkill: Bool = true

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
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
            Text("Install Hardening Baseline")
                .font(Typography.panelTitle)
            Spacer()
        }
        .padding(Spacing.lg)
    }

    // MARK: Review

    private var reviewBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section(title: "Files that will be created") {
                    bullet("~/.claude/hooks/claudoscope-protect-file.sh")
                    bullet("~/.claude/hooks/claudoscope-validate-commands.sh")
                    bullet("~/.claude/hooks/claudoscope-check-public-repo.sh")
                    bullet("~/.claude/hooks/claudoscope-flag-proprietary-files.sh")
                    bullet("~/.claude/hooks/claudoscope-check-package-age.sh")
                    bullet("~/.claude/hooks/claudoscope-check-git-reset-hard.sh")
                    bullet("~/.claude/hooks/claudoscope-scan-for-credentials.sh")
                    bullet("~/.claude/skills/claudoscope-security-awareness.md")
                    bullet("~/.claude/\(HardeningInstaller.markerFileName)")
                }

                section(title: "Files that will be modified") {
                    bullet("~/.claude/settings.json (deny rules, sandbox, hooks, autoMode merged)")
                    bullet("~/.claude/CLAUDE.md (governance block appended between markers)")
                }

                section(title: "Backup destination") {
                    bullet("~/.claude/.claudoscope-hardening-backup-<yyyyMMdd-HHmmss>/")
                    Text("Existing settings.json, CLAUDE.md, and hooks/ are copied here before any change.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 16)
                }

                section(title: "Layers") {
                    layerToggle(text: "Layer 1: permissions.deny baseline", isOn: $optionLayer1Permissions)
                    layerToggle(text: "Layer 1: sandbox baseline (filesystem + network)", isOn: $optionLayer1Sandbox)
                    layerToggle(text: "Layer 2: hook scripts and registrations", isOn: $optionLayer2Hooks)
                    layerToggle(text: "Layer 3: autoMode allowlist", isOn: $optionLayer3AutoMode)
                    layerToggle(text: "Layer 4: governance block in CLAUDE.md", isOn: $optionLayer4Governance)
                    layerToggle(text: "Skill: claudoscope-security-awareness", isOn: $optionSkill)
                }
            }
            .padding(Spacing.lg)
        }
    }

    // MARK: Installing

    private var installingBody: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView().controlSize(.large)
            Text("Installing baseline...")
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
                    Text("Baseline installed")
                        .font(Typography.bodyMedium)
                }

                if let result = resultSummary {
                    section(title: "Layers applied") {
                        ForEach(result.layersApplied, id: \.self) { layer in
                            bullet(layer)
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
                        Text(claudeDirURL.appendingPathComponent(HardeningInstaller.markerFileName).path)
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
                    onCompleted(ActionResult(message: "Hardening baseline installed.", isError: false))
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

    private func runInstall() {
        guard let installer else {
            errorMessage = "Installer is not available."
            phase = .error
            return
        }
        let opts = HardeningInstallOptions(
            layer1Permissions: optionLayer1Permissions,
            layer1Sandbox: optionLayer1Sandbox,
            layer2Hooks: optionLayer2Hooks,
            layer3AutoMode: optionLayer3AutoMode,
            layer4Governance: optionLayer4Governance,
            skill: optionSkill
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

    private func layerToggle(text: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(text)
                .font(Typography.body)
        }
        .toggleStyle(.checkbox)
    }
}
