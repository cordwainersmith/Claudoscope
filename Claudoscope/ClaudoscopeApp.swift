import SwiftUI

@main
struct ClaudoscopeApp: App {
    @State private var store = SessionStore()

    var body: some Scene {
        // Menu bar popover (always present)
        MenuBarExtra {
            MenuBarPopoverContent()
                .environment(store)
        } label: {
            Label("Claudoscope", systemImage: "chevron.left.forwardslash.chevron.right")
        }
        .menuBarExtraStyle(.window)
    }
}

/// The popover content that can open the full window via NSWindow
struct MenuBarPopoverContent: View {
    @Environment(SessionStore.self) private var store
    @State private var showAbout = false
    @AppStorage("hasSeenRepositionTip") private var hasSeenTip = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Claudoscope")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Today's stats
            StatsStrip(
                sessionCount: store.todaySessions.count,
                tokenCount: store.todayTokens,
                cost: store.todayCost,
                projectCount: Set(store.todaySessions.map(\.projectId)).count
            )

            // Sparkline
            SparklineChart(dailyUsage: store.analyticsData.dailyUsage)
                .padding(.bottom, 12)

            Divider()

            // Active session (if any)
            if let activeSession = findActiveSession() {
                ActiveSessionCard(session: activeSession)
                    .padding(.vertical, 8)
                Divider()
            }

            // Recent sessions
            if !store.recentSessions.isEmpty {
                RecentSessionsList(sessions: store.recentSessions) { _ in
                    MainWindowController.shared.open(store: store)
                }
                .padding(.vertical, 8)
                Divider()
            }

            // Reposition tip (shown once)
            if !hasSeenTip {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Hold **Cmd** and drag the menu bar icon to reposition it.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button {
                        hasSeenTip = true
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
            }

            // Actions
            VStack(spacing: 0) {
                PopoverMenuButton(label: "Open full view...", shortcut: "Cmd+O") {
                    MainWindowController.shared.open(store: store)
                }

                PopoverMenuButton(label: "About Claudoscope") {
                    showAbout = true
                }

                PopoverMenuButton(label: "Quit Claudoscope", shortcut: "Cmd+Q") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .frame(width: 280)
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
    }

    private func findActiveSession() -> SessionSummary? {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return store.allSessionsWithProjects
            .map(\.session)
            .first { session in
                guard let date = isoFormatter.date(from: session.lastTimestamp) else { return false }
                return now.timeIntervalSince(date) < 60
            }
    }
}

/// NSWindow subclass that reverts the app to accessory (no Dock icon) when closed.
final class PersistentWindow: NSWindow {
    override func close() {
        super.close()
        // Hide from Dock again when the full window is closed
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

/// Manages the main NSWindow directly, bypassing SwiftUI's Window scene limitations
final class MainWindowController {
    static let shared = MainWindowController()

    private var window: NSWindow?

    func open(store: SessionStore) {
        // If window exists and is visible, just bring it forward
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        // Show the app in the Dock while the full window is open
        NSApplication.shared.setActivationPolicy(.regular)

        let contentView = FullWindowView()
            .environment(store)
            .frame(minWidth: 900, minHeight: 600)

        let hostingView = NSHostingView(rootView: contentView)

        let window = PersistentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claudoscope"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("ClaudoscopeMainWindow")
        window.appearance = store.appearance.nsAppearance
        window.makeKeyAndOrderFront(nil)

        NSApplication.shared.activate(ignoringOtherApps: true)

        self.window = window
    }

    func applyAppearance(_ appearance: AppAppearance) {
        window?.appearance = appearance.nsAppearance
    }
}

// MARK: - Popover Menu Button

struct PopoverMenuButton: View {
    let label: String
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)

            Text("Claudoscope")
                .font(.system(size: 18, weight: .medium))

            Text("Session explorer for Claude Code")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text("Version 1.0.0")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            Divider()
                .frame(width: 120)

            Button("OK") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 280)
    }
}
