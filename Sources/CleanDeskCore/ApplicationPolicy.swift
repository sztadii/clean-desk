import Foundation

/// A stable application identity: process IDs deliberately never form an allowlist key.
public enum ApplicationIdentity {
    public static func key(bundleIdentifier: String?, path: String?) -> String? {
        if let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty {
            return "bundle:\(identifier.lowercased())"
        }
        guard let path, !path.isEmpty else { return nil }
        return "path:\(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path)"
    }
}

public struct RunningApplicationRecord: Equatable {
    public let processIdentifier: Int32
    public let bundleIdentifier: String?
    public let path: String?
    public let isRegular: Bool
    public let launchDate: Date?
    public let isHidden: Bool
    public let hasVisibleWindows: Bool

    public init(processIdentifier: Int32, bundleIdentifier: String?, path: String?, isRegular: Bool, launchDate: Date?, isHidden: Bool = false, hasVisibleWindows: Bool = false) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.isRegular = isRegular
        self.launchDate = launchDate
        self.isHidden = isHidden
        self.hasVisibleWindows = hasVisibleWindows
    }

    public var applicationKey: String? {
        ApplicationIdentity.key(bundleIdentifier: bundleIdentifier, path: path)
    }

    /// A restarted process must not inherit an earlier cleanup request, even if its PID is reused.
    public func identifiesSameProcess(as other: RunningApplicationRecord) -> Bool {
        processIdentifier == other.processIdentifier
            && applicationKey != nil
            && applicationKey == other.applicationKey
            && launchDate == other.launchDate
    }
}

public struct ApplicationPolicy {
    public let ownProcessIdentifier: Int32
    public let ownBundleIdentifier: String?

    public init(ownProcessIdentifier: Int32, ownBundleIdentifier: String?) {
        self.ownProcessIdentifier = ownProcessIdentifier
        self.ownBundleIdentifier = ownBundleIdentifier?.lowercased()
    }

    public func isEligible(_ app: RunningApplicationRecord) -> Bool {
        guard app.isRegular, app.processIdentifier != ownProcessIdentifier, app.applicationKey != nil else { return false }
        let identifier = app.bundleIdentifier?.lowercased()
        if identifier == "com.apple.finder" { return false }
        if let ownBundleIdentifier, identifier == ownBundleIdentifier { return false }
        return true
    }

    public func shouldTerminate(_ app: RunningApplicationRecord, protectedKeys: Set<String>) -> Bool {
        guard isEligible(app), let key = app.applicationKey else { return false }
        return !protectedKeys.contains(key)
    }

    /// Finder manages the Desktop, so clean up its visible windows by hiding
    /// the application without terminating its process.
    public func shouldHide(_ app: RunningApplicationRecord, protectedKeys: Set<String>) -> Bool {
        guard app.bundleIdentifier?.lowercased() == "com.apple.finder",
              app.isRegular, app.processIdentifier != ownProcessIdentifier,
              app.bundleIdentifier?.lowercased() != ownBundleIdentifier,
              !app.isHidden, app.hasVisibleWindows,
              let key = app.applicationKey else { return false }
        return !protectedKeys.contains(key)
    }

    /// A selected Finder may still be running after an earlier cleanup hid it.
    /// Restore its existing windows without launching or activating a new app.
    public func shouldUnhide(_ app: RunningApplicationRecord, protectedKeys: Set<String>) -> Bool {
        guard app.bundleIdentifier?.lowercased() == "com.apple.finder",
              app.isRegular, app.processIdentifier != ownProcessIdentifier,
              app.bundleIdentifier?.lowercased() != ownBundleIdentifier,
              app.isHidden, let key = app.applicationKey else { return false }
        return protectedKeys.contains(key)
    }

    /// Keep every process instance; only the presentation layer groups apps into rows.
    public func candidates(from apps: [RunningApplicationRecord], protectedKeys: Set<String>) -> [RunningApplicationRecord] {
        apps.filter { shouldTerminate($0, protectedKeys: protectedKeys) }
    }
}

/// An immutable plan made before opening any apps. Only saved choices may be
/// opened, while termination is restricted to the original eligible processes.
public struct DeskPlan {
    public let applicationKeysToLaunch: Set<String>
    public let processesToTerminate: [RunningApplicationRecord]
    public let processesToHide: [RunningApplicationRecord]
    public let processesToUnhide: [RunningApplicationRecord]

    public init(running: [RunningApplicationRecord], protectedKeys: Set<String>, policy: ApplicationPolicy) {
        let runningKeys = Set(running.compactMap(\.applicationKey))
        applicationKeysToLaunch = protectedKeys.subtracting(runningKeys)
        processesToTerminate = policy.candidates(from: running, protectedKeys: protectedKeys)
        processesToHide = running.filter { policy.shouldHide($0, protectedKeys: protectedKeys) }
        processesToUnhide = running.filter { policy.shouldUnhide($0, protectedKeys: protectedKeys) }
    }
}
