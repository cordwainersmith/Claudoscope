import SwiftUI

@main
struct ClaudoscopeApp: App {
    @State private var store = SessionStore()
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some Scene {
        // Menu bar popover (always present)
        MenuBarExtra {
            MenuBarPopoverContent()
                .environment(store)
        } label: {
            MenuBarIcon()
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        if !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                OnboardingWindowController.shared.show()
            }
        }
    }
}

/// Loads the custom menu bar icon from bundle resources
struct MenuBarIcon: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "menu-bar-icon", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            nsImage.isTemplate = false
            return AnyView(Image(nsImage: nsImage)
                .renderingMode(.original))
        } else {
            return AnyView(Image(systemName: "chevron.left.forwardslash.chevron.right"))
        }
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
                Text("CLAUDOSCOPE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.5)
                Spacer()
                if let url = Bundle.main.url(forResource: "logo-c-t", withExtension: "png"),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            if store.isLoading {
                // Loading skeleton
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        ForEach(0..<4) { _ in
                            RoundedRectangle(cornerRadius: 6)
                                .fill(.quaternary)
                                .frame(height: 40)
                        }
                    }
                    .padding(.horizontal, 16)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quaternary)
                        .frame(height: 50)
                        .padding(.horizontal, 16)

                    ForEach(0..<3) { _ in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(.quaternary)
                                .frame(width: 24, height: 24)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                                .frame(height: 14)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 12)
                .redacted(reason: .placeholder)

                Divider()
            } else {
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
                        .fixedSize(horizontal: false, vertical: true)
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
                PopoverMenuButton(label: "Dashboard", systemImage: "macwindow", shortcut: "Cmd+O") {
                    MainWindowController.shared.open(store: store)
                }

                Divider()

                PopoverMenuButton(label: "About Claudoscope", systemImage: "info.circle") {
                    showAbout = true
                }

                PopoverMenuButton(label: "Quit Claudoscope", systemImage: "power", shortcut: "Cmd+Q") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .frame(width: 280)
        .overlay {
            if showAbout {
                AboutOverlay {
                    showAbout = false
                }
            }
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

        // Use the rounded icon as the Dock icon
        if let iconURL = Bundle.main.url(forResource: "app-icon-rounded", withExtension: "png"),
           let iconImage = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = iconImage
        }

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
    var systemImage: String? = nil
    var shortcut: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                        .frame(width: 16)
                }
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

// MARK: - Onboarding Window

final class OnboardingWindowController {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    func show() {
        guard window == nil else { return }

        let contentView = OnboardingView {
            self.dismiss()
        }

        let hostingView = NSHostingView(rootView: contentView)

        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Claudoscope"
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Show briefly in Dock so the window is visible
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        self.window = window
    }

    private func dismiss() {
        window?.close()
        window = nil
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

struct OnboardingView: View {
    let onDismiss: () -> Void
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var dontShowAgain = false

    private var logoImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "logo-c-t", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = false
        return img
    }

    private var menuBarImage: NSImage? {
        guard let url = Bundle.main.url(forResource: "menu-bar-icon", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = false
        return img
    }

    var body: some View {
        VStack(spacing: 20) {
            // App icon
            if let nsImage = logoImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 56, height: 56)
            }

            Text("Claudoscope lives in your menu bar")
                .font(.system(size: 16, weight: .semibold))

            // Menu bar icon illustration
            HStack(spacing: 10) {
                Text("Look for this icon:")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                if let nsImage = menuBarImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 22, height: 22)
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.quaternary)
                        )
                }

                Text("in your menu bar")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            // Notch tip
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)

                    Text("If you can't see it, the icon might be hidden behind the notch. Hold **\u{2318} Cmd** and drag other menu bar icons to the left to make room.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.08))
                    .strokeBorder(Color.orange.opacity(0.15), lineWidth: 1)
            )

            Divider()

            // Don't show again + Got it
            HStack {
                Toggle("Don't show this again", isOn: $dontShowAgain)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Got it") {
                    if dontShowAgain {
                        hasSeenOnboarding = true
                    }
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - About View

struct AboutOverlay: View {
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Tap anywhere to dismiss
            Color.black.opacity(0.4)
                .onTapGesture { onDismiss() }

            VStack(spacing: 12) {
                if let url = Bundle.main.url(forResource: "logo-c-t", withExtension: "png"),
                   let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                }

                Text("Claudoscope")
                    .font(.system(size: 16, weight: .medium))

                Text("Session explorer for Claude Code")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Text("Version 0.3.1")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Link(destination: URL(string: "https://github.com/cordwainersmith/Claudoscope")!) {
                    Text("github.com/cordwainersmith/Claudoscope")
                        .font(.system(size: 11))
                    .foregroundStyle(.blue)
                }
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThickMaterial)
            )
        }
        .transition(.opacity)
    }
}
