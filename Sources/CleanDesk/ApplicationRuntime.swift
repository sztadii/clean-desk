import AppKit
import CleanDeskCore

/// The only adapter that opens apps or sends AppKit process requests. The
/// coordinator uses the same interface with fake processes in its flow tests.
@MainActor
final class ApplicationRuntime {
    private let workspace: NSWorkspace
    private let applicationURL: (String) -> URL?
    private let icons: ApplicationIconCache
    private var cachedRows: [String: ManagedApplication] = [:]

    init(workspace: NSWorkspace, icons: ApplicationIconCache? = nil, applicationURL: ((String) -> URL?)? = nil) {
        self.workspace = workspace
        self.applicationURL = applicationURL ?? { workspace.urlForApplication(withBundleIdentifier: $0) }
        self.icons = icons ?? .shared
    }

    func runningApplications() -> [any CleanupProcess] {
        workspace.runningApplications.filter { !$0.isTerminated }.map {
            WorkspaceProcess(application: $0, runtime: self)
        }
    }

    func invalidatePresentationCache() {
        cachedRows.removeAll()
        icons.invalidate()
    }

    func resolve(_ app: SavedApplication) -> URL? {
        var candidates: [URL] = []
        // Launch the selected installation before consulting Launch Services,
        // which may point at a development or outdated copy with the same ID.
        if let path = app.path { candidates.append(URL(fileURLWithPath: path)) }
        if let identifier = app.bundleIdentifier,
           let url = applicationURL(identifier) { candidates.append(url) }
        return candidates.first { url in
            guard FileManager.default.fileExists(atPath: url.path), let bundle = Bundle(url: url) else { return false }
            // An old path may now belong to another app. Never launch it unless
            // its identity still matches the user's saved selection.
            return ApplicationIdentity.key(bundleIdentifier: bundle.bundleIdentifier, path: url.path) == app.id
        }
    }

    func launch(_ app: SavedApplication, completion: @escaping @MainActor ((any CleanupProcess)?, String?) -> Void) {
        guard let url = resolve(app) else {
            completion(nil, "the installed application could not be found")
            return
        }
        // A launcher started from an Electron development tool can inherit
        // this flag. Launch Services passes it on even with an empty OpenConfiguration
        // environment, making Electron favourites run as Node without a UI.
        // Remove it from the actual process environment, rather than copying
        // ProcessInfo.environment (which may be cached) into the launch request.
        unsetenv("ELECTRON_RUN_AS_NODE")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        workspace.openApplication(at: url, configuration: configuration) { [weak self] application, error in
            Task { @MainActor in
                guard let self else { return }
                if let application, Self.record(for: application).applicationKey == app.id {
                    completion(WorkspaceProcess(application: application, runtime: self), nil)
                } else {
                    completion(nil, error.map { "macOS could not open the application: \($0.localizedDescription)" } ?? "macOS did not confirm that the application opened")
                }
            }
        }
    }

    static func record(for app: NSRunningApplication) -> RunningApplicationRecord {
        RunningApplicationRecord(
            processIdentifier: app.processIdentifier, bundleIdentifier: app.bundleIdentifier,
            path: app.bundleURL?.path, isRegular: app.activationPolicy == .regular, launchDate: app.launchDate,
            isHidden: app.isHidden,
            hasVisibleWindows: app.bundleIdentifier?.lowercased() == "com.apple.finder" && !app.isHidden
                && FinderWindows.hasVisibleWindow(processIdentifier: app.processIdentifier)
        )
    }

    fileprivate func row(for app: NSRunningApplication) -> ManagedApplication {
        let id = ApplicationIdentity.key(bundleIdentifier: app.bundleIdentifier, path: app.bundleURL?.path)
            ?? "process:\(app.processIdentifier)"
        let cacheKey = id + ":" + (app.bundleURL?.path ?? "")
        if let cached = cachedRows[cacheKey] { return cached }
        let row = ManagedApplication(
            id: id,
            name: ApplicationName.displayName(for: app.bundleURL, fallback: app.localizedName ?? "Application"),
            icon: icons.icon(at: app.bundleURL?.path) { app.icon },
            bundleIdentifier: app.bundleIdentifier, url: app.bundleURL
        )
        cachedRows[cacheKey] = row
        return row
    }
}

@MainActor
private final class WorkspaceProcess: CleanupProcess {
    let application: NSRunningApplication
    let runtime: ApplicationRuntime

    init(application: NSRunningApplication, runtime: ApplicationRuntime) {
        self.application = application
        self.runtime = runtime
    }

    var record: RunningApplicationRecord { ApplicationRuntime.record(for: application) }
    var row: ManagedApplication { runtime.row(for: application) }
    var isTerminated: Bool { application.isTerminated }

    func currentRecord() -> RunningApplicationRecord? {
        guard !application.isTerminated,
              let current = NSRunningApplication(processIdentifier: application.processIdentifier),
              !current.isTerminated else { return nil }
        return ApplicationRuntime.record(for: current)
    }

    func terminate() { _ = application.terminate() }
    func hide() { _ = application.hide() }
    func unhide() { _ = application.unhide() }
}
