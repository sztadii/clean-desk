import Foundation

/// Launchable applications discovered locally. The AppKit adapter verifies each
/// bundle and executable before supplying it here; this resolver never launches it.
public struct OnboardingApplication: Equatable {
    public let name: String
    public let bundleIdentifier: String?
    public let path: String

    public init(name: String, bundleIdentifier: String?, path: String) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
    }

    public var key: String? {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "app" else { return nil }
        return ApplicationIdentity.key(bundleIdentifier: bundleIdentifier, path: path)
    }
}

public enum OnboardingSuggestions {
    public static let fallbackBundleIdentifiers = ["com.apple.Safari", "com.apple.Notes"]

    /// Running user apps come first. Fill only missing places with installed
    /// Safari and Notes, without inventing entries for missing applications.
    public static func select(
        running: [RunningApplicationRecord],
        available: [OnboardingApplication],
        policy: ApplicationPolicy
    ) -> [OnboardingApplication] {
        let runningKeys = Set(running.filter { app in
            policy.isEligible(app)
                && app.path.map { URL(fileURLWithPath: $0).pathExtension.lowercased() == "app" } == true
        }.compactMap(\.applicationKey))
        let sorted = available.filter { $0.key != nil }.sorted {
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            return nameOrder == .orderedSame ? $0.path < $1.path : nameOrder == .orderedAscending
        }
        var result: [OnboardingApplication] = []
        var selectedKeys: Set<String> = []
        func append(_ app: OnboardingApplication) {
            guard result.count < 2, let key = app.key, selectedKeys.insert(key).inserted else { return }
            result.append(app)
        }
        for app in sorted where app.key.map(runningKeys.contains) == true { append(app) }
        for identifier in fallbackBundleIdentifiers {
            if let fallback = sorted.first(where: { $0.bundleIdentifier?.lowercased() == identifier.lowercased() }) {
                append(fallback)
            }
        }
        return result
    }
}
