import SwiftUI

/// The popover content that can open the full window via NSWindow
struct MenuBarPopoverContent: View {
    @Environment(SessionStore.self) private var store
    @Environment(UpdateService.self) private var updateService
    @State private var showAbout = false
    @State private var showUpToDate = false
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
                // Loading state with animated logo
                LoadingLogoView()

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

                // Active sessions (if any)
                if !activeSessions.isEmpty {
                    ActiveSessionsCard(sessions: activeSessions)
                        .padding(.vertical, 8)
                    Divider()
                }

                // Recent sessions
                if !store.recentSessions.isEmpty {
                    RecentSessionsList(sessions: store.recentSessions) { _ in
                        MainWindowController.shared.open(store: store, updateService: updateService)
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
                            .font(Typography.micro)
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
                PopoverMenuButton(label: "Dashboard", systemImage: "macwindow", shortcut: "\u{2318}O") {
                    MainWindowController.shared.open(store: store, updateService: updateService)
                }

                Divider()

                UpdateMenuButton(showUpToDate: $showUpToDate)

                Divider()

                PopoverMenuButton(label: "About Claudoscope", systemImage: "info.circle") {
                    showAbout = true
                }

                PopoverMenuButton(label: "Quit Claudoscope", systemImage: "power", shortcut: "\u{2318}Q") {
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

    private var activeSessions: [SessionSummary] {
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return store.allSessionsWithProjects
            .map(\.session)
            .filter { session in
                guard let date = isoFormatter.date(from: session.lastTimestamp) else { return false }
                return now.timeIntervalSince(date) < 60
            }
    }
}

// MARK: - Popover Menu Button

// MARK: - Loading Logo

struct LoadingLogoView: View {
    @State private var isAnimating = false

    var body: some View {
        VStack(spacing: 14) {
            if let url = Bundle.main.url(forResource: "logo-c-t", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 48, height: 48)
                    .scaleEffect(isAnimating ? 1.06 : 0.94)
                    .opacity(isAnimating ? 1.0 : 0.6)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: isAnimating
                    )
            }

            Text("Loading sessions...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .opacity(isAnimating ? 1.0 : 0.5)
                .animation(
                    .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                    value: isAnimating
                )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .onAppear { isAnimating = true }
    }
}

struct PopoverMenuButton: View {
    let label: String
    var systemImage: String? = nil
    var shortcut: String? = nil
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(Typography.body)
                        .frame(width: 16)
                }
                Text(label)
                    .font(Typography.body)
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct UpdateMenuButton: View {
    @Environment(UpdateService.self) private var updateService
    @Binding var showUpToDate: Bool
    @State private var isHovered = false

    var body: some View {
        Button {
            Task {
                showUpToDate = false
                updateService.clearSkippedVersion()
                await updateService.checkForUpdates()
                if updateService.updateAvailable == nil, updateService.error == nil {
                    showUpToDate = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        showUpToDate = false
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(Typography.body)
                    .frame(width: 16)
                Text(showUpToDate ? "You're up to date!" : "Check for Updates...")
                    .font(Typography.body)
                    .foregroundStyle(showUpToDate ? .green : .primary)
                Spacer()
                if updateService.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else if showUpToDate {
                    Image(systemName: "checkmark.circle.fill")
                        .font(Typography.body)
                        .foregroundStyle(.green)
                } else if updateService.updateAvailable != nil {
                    Text("New")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.orange))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
