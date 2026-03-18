import SwiftUI

// MARK: - Window Content Wrappers

struct UpdateAvailableWindowContent: View {
    @Environment(UpdateService.self) private var updateService
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let update = updateService.updateAvailable {
            UpdateAvailableView(
                update: update,
                updateService: updateService,
                onDismiss: { dismissWindow(id: "update-available") },
                onSkip: {
                    updateService.skipVersion(update.version)
                    dismissWindow(id: "update-available")
                }
            )
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear { dismissWindow(id: "update-available") }
        }
    }
}

struct WhatsNewWindowContent: View {
    @Environment(UpdateService.self) private var updateService
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var entries: [ChangelogEntry] = []
    @State private var isLoading = true

    var body: some View {
        if updateService.whatsNewInfo != nil {
            WhatsNewView(
                entries: entries,
                highlightVersion: updateService.whatsNewInfo?.version,
                isLoading: isLoading,
                onDismiss: {
                    updateService.whatsNewInfo = nil
                    dismissWindow(id: "whats-new")
                }
            )
            .task {
                entries = await ChangelogParser.fetchEntries()
                isLoading = false
            }
        } else {
            Color.clear
                .frame(width: 0, height: 0)
                .onAppear { dismissWindow(id: "whats-new") }
        }
    }
}

// MARK: - Activation Policy Management

private struct ActivationPolicyModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onAppear {
                NSApplication.shared.setActivationPolicy(.regular)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            .onDisappear {
                let hasOtherVisibleWindow = NSApp.windows.contains { w in
                    w.isVisible && w.level == .normal
                }
                if !hasOtherVisibleWindow {
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
            }
    }
}

// MARK: - Update Available View

struct UpdateAvailableView: View {
    let update: UpdateService.UpdateInfo
    let updateService: UpdateService
    let onDismiss: () -> Void
    var onSkip: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            if let nsImage = loadAppIcon() {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            }

            VStack(spacing: 4) {
                Text("Claudoscope \(update.version) is available")
                    .font(.system(size: 15, weight: .semibold))

                Text("You're currently on version \(updateService.currentVersion)")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
            }

            if let notes = update.releaseNotes, !notes.isEmpty {
                ScrollView {
                    MarkdownNotesView(markdown: notes)
                        .padding(10)
                }
                .frame(height: 200)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(AnyShapeStyle(.quaternary))
                )
            }

            VStack(spacing: 8) {
                HStack {
                    Button("Later") {
                        updateService.updateAvailable = nil
                        onDismiss()
                    }

                    Spacer()

                    if updateService.isDownloading {
                        ProgressView(value: updateService.downloadProgress)
                            .frame(width: 80)
                        Text("\(Int(updateService.downloadProgress * 100))%")
                            .font(Typography.code)
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Download and Install") {
                            updateService.downloadAndInstall()
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }

                if !updateService.isDownloading {
                    HStack {
                        Button("Skip This Version") {
                            updateService.updateAvailable = nil
                            onSkip?()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 400)
        .modifier(ActivationPolicyModifier())
    }
}

// MARK: - What's New View (Full Changelog)

struct WhatsNewView: View {
    var entries: [ChangelogEntry]
    var highlightVersion: String?
    var isLoading: Bool = false
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if let nsImage = loadAppIcon() {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
            }

            Text("Release Notes")
                .font(.system(size: 15, weight: .semibold))

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else if entries.isEmpty {
                Text("No release notes available.")
                    .font(Typography.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(entries, id: \.version) { entry in
                                ChangelogEntryView(
                                    entry: entry,
                                    isHighlighted: entry.version == highlightVersion
                                )
                                .id(entry.version)

                                if entry.version != entries.last?.version {
                                    Divider()
                                        .padding(.vertical, 8)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .frame(height: 400)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(AnyShapeStyle(.quaternary))
                    )
                    .onAppear {
                        if let version = highlightVersion {
                            proxy.scrollTo(version, anchor: .top)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("OK") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .modifier(ActivationPolicyModifier())
    }
}

// MARK: - Changelog Entry View

private struct ChangelogEntryView: View {
    let entry: ChangelogEntry
    var isHighlighted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("v\(entry.version)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isHighlighted ? Color.accentColor : .primary)

                if isHighlighted {
                    Text("current")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(.tint))
                }

                Spacer()

                if let url = entry.releaseURL {
                    Link(destination: url) {
                        HStack(spacing: 3) {
                            Text("Release")
                                .font(.system(size: 11))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }

            MarkdownNotesView(markdown: entry.notes)
        }
    }
}

// MARK: - Markdown Notes Renderer

struct MarkdownNotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(parseLines().enumerated()), id: \.offset) { _, element in
                switch element {
                case .header(let text, let level):
                    Text(text)
                        .font(level <= 2
                            ? .system(size: 13, weight: .semibold)
                            : .system(size: 12, weight: .medium))
                        .foregroundStyle(level <= 2 ? .primary : .secondary)
                        .padding(.top, 4)

                case .bullet(let attributed):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\u{2022}")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(attributed)
                            .font(Typography.body)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                case .text(let attributed):
                    Text(attributed)
                        .font(Typography.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Line {
        case header(String, Int)
        case bullet(AttributedString)
        case text(AttributedString)
    }

    private func parseLines() -> [Line] {
        var result: [Line] = []
        for raw in markdown.components(separatedBy: .newlines) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Strip "Full Changelog" link lines
            if trimmed.hasPrefix("**Full Changelog**") { continue }

            if trimmed.hasPrefix("### ") {
                let text = String(trimmed.dropFirst(4))
                result.append(.header(text, 3))
            } else if trimmed.hasPrefix("## ") {
                let text = String(trimmed.dropFirst(3))
                result.append(.header(text, 2))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let text = String(trimmed.dropFirst(2))
                result.append(.bullet(inlineMarkdown(text)))
            } else {
                result.append(.text(inlineMarkdown(trimmed)))
            }
        }
        return result
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
