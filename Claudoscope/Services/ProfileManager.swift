import Foundation
import Combine
import Observation

@Observable
final class ProfileManager {

    var profiles: [ClaudeProfile]
    var activeProfile: ClaudeProfile

    /// Combine bridge — SessionStore subscribes here for live reload.
    @ObservationIgnored
    let activeProfileChanged = PassthroughSubject<ClaudeProfile, Never>()

    @ObservationIgnored
    private let defaults = UserDefaults.standard

    private static let profilesKey = "claudeProfiles"
    private static let activeProfileIdKey = "activeProfileId"

    init() {
        let saved = ProfileManager.loadSavedProfiles()
        let activeId = UserDefaults.standard
            .string(forKey: ProfileManager.activeProfileIdKey)
            .flatMap { UUID(uuidString: $0) }

        if saved.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let defaultProfile = ClaudeProfile(
                name: "Default",
                path: home.appendingPathComponent(".claude").path
            )
            self.profiles = [defaultProfile]
            self.activeProfile = defaultProfile
        } else {
            self.profiles = saved
            self.activeProfile = saved.first(where: { $0.id == activeId }) ?? saved[0]
        }
        save()
    }

    func add(name: String, path: String) {
        profiles.append(ClaudeProfile(name: name, path: path))
        save()
    }

    func update(_ profile: ClaudeProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        if profile.id == activeProfile.id {
            activeProfile = profile
            activeProfileChanged.send(profile)
        }
        save()
    }

    func delete(_ profile: ClaudeProfile) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == profile.id }
        if profile.id == activeProfile.id {
            activeProfile = profiles[0]
            activeProfileChanged.send(activeProfile)
        }
        save()
    }

    /// Returns false (and does NOT switch) if the path does not exist on disk.
    @discardableResult
    func activate(_ profile: ClaudeProfile) -> Bool {
        guard FileManager.default.fileExists(atPath: profile.path) else { return false }
        activeProfile = profile
        defaults.set(profile.id.uuidString, forKey: ProfileManager.activeProfileIdKey)
        activeProfileChanged.send(profile)
        return true
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: ProfileManager.profilesKey)
        defaults.set(activeProfile.id.uuidString, forKey: ProfileManager.activeProfileIdKey)
    }

    private static func loadSavedProfiles() -> [ClaudeProfile] {
        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([ClaudeProfile].self, from: data)
        else { return [] }
        return profiles
    }
}
