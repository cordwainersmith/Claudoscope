import Foundation

/// Owns the embedded MCP server lifecycle and its Claude Code registration.
/// Mirrors `CanonService`: a Codable config persisted to UserDefaults with
/// `didSet`, injected into the SwiftUI environment.
@MainActor @Observable
final class McpServerService {
    var config: McpServerConfig {
        didSet { persist() }
    }
    private(set) var status: McpServerStatus = .stopped
    private(set) var registration: McpRegistrationState = .unknown

    @ObservationIgnored private weak var store: SessionStore?
    @ObservationIgnored private weak var canonService: CanonService?
    @ObservationIgnored private var socketServer: McpSocketServer?
    @ObservationIgnored private let claudeDir: URL

    private static let defaultsKey = "mcpServerConfig"

    static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Claudoscope/mcp.sock")
    }

    init(claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) {
        self.claudeDir = claudeDir
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(McpServerConfig.self, from: data) {
            self.config = decoded
        } else {
            self.config = .default
        }
    }

    func attach(store: SessionStore, canonService: CanonService) {
        self.store = store
        self.canonService = canonService
    }

    /// App-launch resume: start the server if the toggle was left on.
    /// Registration is not re-run; it persists in ~/.claude.json.
    func startIfEnabled() async {
        guard config.enabled else { return }
        await startServer()
        if case .running = status {
            registration = .registered
        }
    }

    func enable() async {
        await startServer()
        guard case .running = status else { return }
        config.enabled = true
        await registerWithClaudeCode()
    }

    func disable() async {
        await unregisterFromClaudeCode()
        await stopServer()
        config.enabled = false
        status = .stopped
    }

    func refreshClientCount() async {
        guard let socketServer else { return }
        if case .running = status {
            status = .running(clientCount: await socketServer.clientCount)
        }
    }

    /// The bundled shim binary, or the SPM sibling build product in dev mode.
    nonisolated func shimPath() -> String? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "claudoscope-mcp"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        if let sibling = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("claudoscope-mcp"),
           FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling.path
        }
        return nil
    }

    var manualRegisterCommand: String? {
        shimPath().map { "claude mcp add -s user \(McpToolRegistry.serverName) \"\($0)\"" }
    }

    // MARK: - Server lifecycle

    private func startServer() async {
        guard socketServer == nil else { return }
        status = .starting
        let context = makeContext()
        let server = McpSocketServer(
            socketURL: Self.socketURL,
            makeServer: { await McpToolRegistry.makeServer(context: context) },
            onClientCountChange: { [weak self] count in
                Task { @MainActor [weak self] in
                    guard let self, case .running = self.status else { return }
                    self.status = .running(clientCount: count)
                }
            }
        )
        do {
            try await server.start()
            socketServer = server
            status = .running(clientCount: 0)
        } catch {
            status = .error("\(error)")
        }
    }

    private func stopServer() async {
        guard let server = socketServer else { return }
        socketServer = nil
        await server.stop()
    }

    private func makeContext() -> McpToolContext {
        McpToolContext(
            snapshot: { @MainActor [weak store, weak canonService] in
                guard let store else { return .empty }
                return McpStoreSnapshot(
                    projects: store.projects,
                    sessionsByProject: store.sessionsByProject,
                    pricingTable: store.pricingTable,
                    canonOptedInProjectIds: canonService?.config.optedInProjectIds ?? [],
                    bundledCanonProtocolVersion: canonService?.bundledProtocolVersion ?? 0
                )
            },
            configService: ConfigService(claudeDir: claudeDir),
            linterService: ConfigLinterService(),
            plansService: PlansService(claudeDir: claudeDir),
            claudeDir: claudeDir
        )
    }

    // MARK: - Claude Code registration (via the official CLI, never by
    // editing ~/.claude.json ourselves)

    private func registerWithClaudeCode() async {
        guard let shim = shimPath() else {
            registration = .cliNotFound(manualCommand: "claude mcp add -s user \(McpToolRegistry.serverName) <path-to-claudoscope-mcp>")
            return
        }
        guard let cli = await locateCli() else {
            registration = .cliNotFound(manualCommand: manualRegisterCommand ?? "")
            return
        }
        store?.setInstallInProgress(true)
        defer { store?.setInstallInProgress(false) }
        // Remove-then-add keeps re-enabling idempotent and heals stale shim paths.
        _ = await runCli(cli, ["mcp", "remove", "-s", "user", McpToolRegistry.serverName])
        let result = await runCli(cli, ["mcp", "add", "-s", "user", McpToolRegistry.serverName, shim])
        switch result {
        case .success:
            registration = .registered
        case .failure(let message):
            registration = .failed(message)
        }
    }

    private func unregisterFromClaudeCode() async {
        guard let cli = await locateCli() else {
            registration = .cliNotFound(manualCommand: "claude mcp remove -s user \(McpToolRegistry.serverName)")
            return
        }
        store?.setInstallInProgress(true)
        defer { store?.setInstallInProgress(false) }
        switch await runCli(cli, ["mcp", "remove", "-s", "user", McpToolRegistry.serverName]) {
        case .success:
            registration = .notRegistered
        case .failure(let message):
            registration = .failed(message)
        }
    }

    private func locateCli() async -> URL? {
        await Task.detached(priority: .userInitiated) {
            ClaudeCliLocator.locate()
        }.value
    }

    private enum CliResult {
        case success
        case failure(String)
    }

    private func runCli(_ cli: URL, _ arguments: [String]) async -> CliResult {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            let stderrPipe = Pipe()
            process.standardOutput = Pipe()
            process.standardError = stderrPipe
            do {
                try process.run()
            } catch {
                return .failure("Could not run \(cli.lastPathComponent): \(error.localizedDescription)")
            }
            let deadline = Date().addingTimeInterval(20)
            while process.isRunning && Date() < deadline {
                usleep(100_000)
            }
            if process.isRunning {
                process.terminate()
                return .failure("\(cli.lastPathComponent) \(arguments.joined(separator: " ")) timed out")
            }
            if process.terminationStatus == 0 {
                return .success
            }
            let stderrData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
            let message = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .failure(message.isEmpty ? "exit code \(process.terminationStatus)" : message)
        }.value
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
