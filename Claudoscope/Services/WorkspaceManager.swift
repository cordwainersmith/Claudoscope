import Foundation
import Combine
import Observation

@Observable
@MainActor
final class WorkspaceManager {

    var workspaces: [Workspace]
    var activeWorkspace: Workspace

    /// Combine bridge — SessionStore subscribes here for live reload.
    @ObservationIgnored
    let activeWorkspaceChanged = PassthroughSubject<Workspace, Never>()

    @ObservationIgnored
    private let defaults = UserDefaults.standard

    private static let workspacesKey = "claudeProfiles"
    private static let activeWorkspaceIdKey = "activeProfileId"

    init() {
        let saved = WorkspaceManager.loadSavedWorkspaces()
        let activeId = UserDefaults.standard
            .string(forKey: WorkspaceManager.activeWorkspaceIdKey)
            .flatMap { UUID(uuidString: $0) }

        if saved.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let defaultWorkspace = Workspace(
                name: "Default",
                path: home.appendingPathComponent(".claude").path
            )
            self.workspaces = [defaultWorkspace]
            self.activeWorkspace = defaultWorkspace
        } else {
            self.workspaces = saved
            self.activeWorkspace = saved.first(where: { $0.id == activeId }) ?? saved[0]
        }
        save()
    }

    func add(name: String, path: String) {
        workspaces.append(Workspace(name: name, path: path))
        save()
    }

    func update(_ workspace: Workspace) {
        guard let idx = workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        workspaces[idx] = workspace
        if workspace.id == activeWorkspace.id {
            activeWorkspace = workspace
            activeWorkspaceChanged.send(workspace)
        }
        save()
    }

    func delete(_ workspace: Workspace) {
        guard workspaces.count > 1 else { return }
        workspaces.removeAll { $0.id == workspace.id }
        if workspace.id == activeWorkspace.id {
            activeWorkspace = workspaces[0]
            activeWorkspaceChanged.send(activeWorkspace)
        }
        save()
    }

    /// Returns false (and does NOT switch) if the path does not exist on disk.
    @discardableResult
    func activate(_ workspace: Workspace) -> Bool {
        guard FileManager.default.fileExists(atPath: workspace.path) else { return false }
        activeWorkspace = workspace
        save()
        activeWorkspaceChanged.send(workspace)
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        defaults.set(data, forKey: WorkspaceManager.workspacesKey)
        defaults.set(activeWorkspace.id.uuidString, forKey: WorkspaceManager.activeWorkspaceIdKey)
    }

    private static func loadSavedWorkspaces() -> [Workspace] {
        guard let data = UserDefaults.standard.data(forKey: workspacesKey),
              let saved = try? JSONDecoder().decode([Workspace].self, from: data)
        else { return [] }
        return saved
    }
}
