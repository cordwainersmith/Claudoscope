import AppKit
import Foundation

/// Focuses the terminal tab/session whose title contains a needle (the project
/// folder name), reproducing the classic session-notify.sh click action now that
/// notifications are delivered in-app. Invoked from a notification tap.
///
/// Sends Apple Events via `osascript`, so the app needs the
/// `com.apple.security.automation.apple-events` entitlement and an
/// `NSAppleEventsUsageDescription` string (hardened runtime, non-sandboxed);
/// without them macOS silently blocks the events. The first tap prompts
/// "Claudoscope wants to control <Terminal>" once per terminal app.
///
/// osascript runs on a background queue with a watchdog, so a busy or hung
/// terminal can never wedge the menu bar UI (an in-process `NSAppleScript` on the
/// main actor could block for the Apple Event timeout).
enum TerminalFocuser {

    /// Known terminals in priority order (user's primary first). Each script
    /// matches the needle against tab/session titles and returns "ok"/"nomatch".
    private static let candidates: [(bundleId: String, script: (String) -> String)] = [
        ("com.mitchellh.ghostty", ghosttyScript),
        ("com.googlecode.iterm2", itermScript),
        ("com.apple.Terminal", terminalScript),
    ]

    /// Focus the terminal tab whose title contains `needle`. Only scripts
    /// terminals that are currently running (never launches one, and limits the
    /// number of Automation prompts). Tries running candidates in priority order
    /// and stops at the first match; if none match but a known terminal is
    /// running, raises the top-priority running one (the "raise the app" fallback
    /// the original did with `open -b`).
    static func focus(matchingTitle needle: String) {
        let trimmed = needle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let running = runningBundleIds()
            let active = candidates.filter { running.contains($0.bundleId) }
            guard !active.isEmpty else { return }
            for candidate in active where runOSA(candidate.script(escape(trimmed))) == "ok" {
                return
            }
            activate(bundleId: active[0].bundleId)
        }
    }

    /// Escape a string for interpolation into an AppleScript string literal.
    /// Backslash first, then the double quote, so a folder name containing either
    /// can't break out of the quotes.
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - AppleScript per terminal (needle is already escaped)

    private static func ghosttyScript(_ needle: String) -> String {
        """
        tell application "Ghostty"
        \trepeat with t in terminals
        \t\ttry
        \t\t\tif (name of t) contains "\(needle)" then
        \t\t\t\tfocus t
        \t\t\t\treturn "ok"
        \t\t\tend if
        \t\tend try
        \tend repeat
        end tell
        return "nomatch"
        """
    }

    private static func itermScript(_ needle: String) -> String {
        """
        tell application "iTerm2"
        \trepeat with w in windows
        \t\trepeat with t in tabs of w
        \t\t\trepeat with s in sessions of t
        \t\t\t\ttry
        \t\t\t\t\tif (name of s) contains "\(needle)" then
        \t\t\t\t\t\tselect w
        \t\t\t\t\t\ttell t to select
        \t\t\t\t\t\tactivate
        \t\t\t\t\t\treturn "ok"
        \t\t\t\t\tend if
        \t\t\t\tend try
        \t\t\tend repeat
        \t\tend repeat
        \tend repeat
        end tell
        return "nomatch"
        """
    }

    /// Terminal.app is best-effort: it does not reliably expose escape-sequence
    /// tab titles to AppleScript. Match a user-set `custom title` per tab first
    /// (precise), then the window `name` (the front tab's title) as a coarse
    /// fallback.
    private static func terminalScript(_ needle: String) -> String {
        """
        tell application "Terminal"
        \trepeat with w in windows
        \t\trepeat with t in tabs of w
        \t\t\ttry
        \t\t\t\tif (custom title of t) contains "\(needle)" then
        \t\t\t\t\tset selected of t to true
        \t\t\t\t\tset frontmost of w to true
        \t\t\t\t\tactivate
        \t\t\t\t\treturn "ok"
        \t\t\t\tend if
        \t\t\tend try
        \t\tend repeat
        \tend repeat
        \trepeat with w in windows
        \t\ttry
        \t\t\tif (name of w) contains "\(needle)" then
        \t\t\t\tset frontmost of w to true
        \t\t\t\tactivate
        \t\t\t\treturn "ok"
        \t\t\tend if
        \t\tend try
        \tend repeat
        end tell
        return "nomatch"
        """
    }

    // MARK: - Helpers

    private static func runningBundleIds() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private static func activate(bundleId: String) {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleId }?
            .activate(options: [.activateAllWindows])
    }

    /// Run an AppleScript via osascript, killed after 5s so a wedged terminal
    /// never hangs us. Returns the trimmed stdout ("ok"/"nomatch"), or nil when
    /// osascript could not run or exited non-zero (script error, no dictionary).
    private static func runOSA(_ source: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", source]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Run a command in a new terminal window

extension TerminalFocuser {

    /// Opens a new window in the highest-priority RUNNING terminal from the
    /// candidates list, cd's to `workingDirectory`, and runs `command`. Falls
    /// back to Terminal.app (always installed) when none is running. Never
    /// reuses an existing tab. Background queue + 5s watchdog via `runOSA`;
    /// a terminal whose dictionary lacks the needed verbs (Ghostty before 1.3)
    /// fails the script and the next candidate is tried.
    static func run(command: String, workingDirectory: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let running = runningBundleIds()
            var order = candidates.map(\.bundleId).filter { running.contains($0) }
            if !order.contains("com.apple.Terminal") { order.append("com.apple.Terminal") }
            for bundleId in order {
                guard let script = runScript(bundleId: bundleId, command: command, workingDirectory: workingDirectory) else { continue }
                if runOSA(script) != nil { return }
            }
        }
    }

    /// Pure script builder, internal for tests. Nil for an unknown bundle id.
    static func runScript(bundleId: String, command: String, workingDirectory: String) -> String? {
        let shellLine = "cd \(shellQuote(workingDirectory)) && \(command)"
        switch bundleId {
        case "com.mitchellh.ghostty":
            return """
            tell application "Ghostty"
            \tset cfg to new surface configuration
            \tset initial working directory of cfg to "\(escape(workingDirectory))"
            \tset win to new window with configuration cfg
            \tdelay 0.3
            \tinput text "\(escape(command))\\n" to focused terminal of selected tab of win
            \tactivate
            end tell
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
            \tset w to (create window with default profile)
            \ttell current session of w to write text "\(escape(shellLine))"
            \tactivate
            end tell
            """
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
            \tdo script "\(escape(shellLine))"
            \tactivate
            end tell
            """
        default:
            return nil
        }
    }

    /// POSIX single-quote shell quoting: ' becomes '\''
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
