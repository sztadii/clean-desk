import CleanDeskCore
import Foundation

/// An unreadable selection is different from the user's explicit empty choice.
/// Loading never repairs or replaces data: recovery requires a new saved choice.
struct ProtectedApplicationSettings {
    enum State {
        case missing
        case valid([SavedApplication])
        case invalid
    }

    enum SaveError: Error {
        case invalidSelection
    }

    private let defaults: UserDefaults
    private let key = "protectedApplications.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load() -> State {
        guard let stored = defaults.object(forKey: key) else { return .missing }
        guard let data = stored as? Data else { return .invalid }
        do {
            let apps = try JSONDecoder().decode([SavedApplication].self, from: data)
            return Self.isValid(apps) ? .valid(apps) : .invalid
        } catch {
            return .invalid
        }
    }

    func save(_ apps: [SavedApplication]) throws {
        guard Self.isValid(apps) else { throw SaveError.invalidSelection }
        let data = try JSONEncoder().encode(apps)
        defaults.set(data, forKey: key)
    }

    private static func isValid(_ apps: [SavedApplication]) -> Bool {
        var identities = Set<String>()
        for app in apps {
            // Accept applications that were moved or uninstalled. The stable
            // identity must remain valid even when their saved location is gone.
            if let identifier = app.bundleIdentifier {
                guard !identifier.isEmpty,
                      identifier.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                      !identifier.contains("/"), !identifier.contains(":") else { return false }
            }
            if let path = app.path {
                guard path.hasPrefix("/"), !path.contains("\0"),
                      URL(fileURLWithPath: path).pathExtension.lowercased() == "app" else { return false }
            }
            guard let identity = ApplicationIdentity.key(bundleIdentifier: app.bundleIdentifier, path: app.path),
                  identity == app.id,
                  identities.insert(identity).inserted else { return false }
        }
        return true
    }
}
