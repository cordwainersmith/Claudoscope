import SwiftUI

/// Whether the window hosting this view is actually on screen.
///
/// `MenuBarExtra(.window)` keeps the popover's view hierarchy alive after it
/// closes, and a `repeatForever` animation in it kept the app rendering at
/// 11 to 14 percent CPU with nothing visible. Animations in the popover read
/// this and pause while the window is hidden.
private struct WindowIsVisibleKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var windowIsVisible: Bool {
        get { self[WindowIsVisibleKey.self] }
        set { self[WindowIsVisibleKey.self] = newValue }
    }
}

extension View {
    /// Tracks the hosting window's occlusion state and publishes it to
    /// descendants as `\.windowIsVisible`.
    func trackWindowVisibility() -> some View {
        modifier(WindowVisibilityModifier())
    }
}

private struct WindowVisibilityModifier: ViewModifier {
    /// Starts false so the first report flips it and kicks off the
    /// `.animation(_, value:)` pulses, which only start on a change.
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .background(WindowVisibilityReader(isVisible: $isVisible))
            .environment(\.windowIsVisible, isVisible)
    }
}

private struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onChange = { isVisible = $0 }
        return view
    }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.onChange = { isVisible = $0 }
    }

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else {
                report()
                return
            }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
            report()
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            // Defer so the binding is not written during a view update.
            DispatchQueue.main.async { [onChange] in onChange?(visible) }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
