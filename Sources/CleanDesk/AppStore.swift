import AppKit
import Combine
import CleanDeskCore

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var applications: [ManagedApplication] = []
    @Published private(set) var protectedApps: [SavedApplication] = []
    @Published private(set) var isCleaning = false
    @Published private(set) var report: CleanupReport?
    @Published private(set) var cleanDesktopEnabled: Bool
    @Published private(set) var desktopFileCount: Int?
    @Published private(set) var isGrantingDesktopAccess = false
    @Published private(set) var needsOnboarding: Bool
    @Published private(set) var isRecoveringSelection = false
    @Published private(set) var onboardingApps: [SavedApplication] = []

    private let workspace: NSWorkspace
    private let defaults: UserDefaults
    private let policy: ApplicationPolicy
    private let desktopAccess: any DesktopAccessProviding
    private let desktopFiles: DesktopFileService
    private let settings: ProtectedApplicationSettings
    private let runtime: ApplicationRuntime
    private let cleanup: CleanupCoordinator
    private lazy var monitor = RefreshMonitor { [weak self] in self?.refresh() }
    private var observers: [NSObjectProtocol] = []
    private var cleanupTask: Task<Void, Never>?
    private var desktopInspectionTask: Task<Void, Never>?
    private var desktopInspectionToken = UUID()
    private var desktopInspectionFailures: [String] = []
    private var desktopInspectionAccessDenied = false
    private var reportDismissTask: Task<Void, Never>?
    private var reportDismissToken = UUID()
    private var dismissedReportSignature: ReportSignature?
    private var desktopFailures: [String] = []
    private var desktopAccessDenied = false
    @Published private var runningKeys: Set<String> = []
    @Published private var hiddenRunningKeys: Set<String> = []
    private var cleanupDesktopAccessDenied = false
    private let cleanDesktopKey = "cleanDesktopEnabled.v1"
    private let onboardingCompletedKey = "onboardingCompleted.v1"

    var targetCount: Int { applications.filter { !isProtected($0) }.count }
    var protectedRunningCount: Int { protectedApps.filter { isRunning($0) }.count }
    var launchCount: Int { protectedApps.filter { needsOpening($0) }.count }
    var finderNeedsHiding: Bool {
        applications.contains { $0.bundleIdentifier?.lowercased() == "com.apple.finder" && !isProtected($0) }
    }
    var cleaningDisabledReason: String? {
        isCleaning ? "Cleanup in progress" : nil
    }

    var desktopAccessDisabledReason: String? {
        isGrantingDesktopAccess ? "Finish the access request" : nil
    }

    var desktopSettingsDisabledReason: String? {
        cleaningDisabledReason ?? desktopAccessDisabledReason
    }

    func canClean(_ mode: CleanupMode) -> Bool {
        cleanupDisabledReason(mode) == nil
    }

    func cleanupDisabledReason(_ mode: CleanupMode) -> String? {
        if let reason = cleaningDisabledReason { return reason }
        if isRecoveringSelection { return "Save your favourites first" }
        if needsOnboarding { return "Finish setup first" }
        if let reason = desktopAccessDisabledReason { return reason }

        let hasDesktopFiles = cleanDesktopEnabled && (desktopFileCount ?? 0) > 0
        switch mode {
        case .keepFavourites:
            guard targetCount == 0, launchCount == 0, !hasDesktopFiles else { return nil }
            return "Nothing to clean"
        case .closeAll:
            guard applications.isEmpty, !hasDesktopFiles else { return nil }
            return "Nothing to clean"
        }
    }
    var desktopInspectionFailed: Bool { !desktopInspectionFailures.isEmpty }
    var desktopNeedsAccess: Bool { cleanupDesktopAccessDenied || desktopAccessDenied || (cleanDesktopEnabled && (!desktopAccess.hasGrant || desktopInspectionAccessDenied)) }
    private var protectedKeys: Set<String> { Set(protectedApps.map(\.id)) }

    init(defaults: UserDefaults = .standard, workspace: NSWorkspace = .shared,
         desktopAccess: (any DesktopAccessProviding)? = nil) {
        self.defaults = defaults
        self.workspace = workspace
        self.needsOnboarding = !defaults.bool(forKey: "onboardingCompleted.v1")
        let access = desktopAccess ?? DesktopAccess(defaults: defaults)
        self.desktopAccess = access
        let files = DesktopFileService(access: access)
        self.desktopFiles = files
        // Permission may expire independently of the user's saved preference.
        self.cleanDesktopEnabled = defaults.bool(forKey: "cleanDesktopEnabled.v1")
        self.settings = ProtectedApplicationSettings(defaults: defaults)
        let runtime = ApplicationRuntime(workspace: workspace)
        self.runtime = runtime
        let policy = ApplicationPolicy(ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier, ownBundleIdentifier: Bundle.main.bundleIdentifier)
        self.policy = policy
        self.cleanup = CleanupCoordinator(policy: policy, environment: CleanupEnvironment(
            runningApplications: { runtime.runningApplications() },
            launch: { app, completion in runtime.launch(app, completion: completion) },
            cleanDesktop: { await files.clean() }
        ))
        switch settings.load() {
        case .valid(let saved):
            protectedApps = saved.map { app in
                SavedApplication(
                    id: app.id,
                    name: ApplicationName.displayName(for: runtime.resolve(app), fallback: app.name),
                    bundleIdentifier: app.bundleIdentifier,
                    path: app.path
                )
            }
        case .missing:
            isRecoveringSelection = !needsOnboarding
        case .invalid:
            isRecoveringSelection = true
        }
        if isRecoveringSelection { needsOnboarding = true }
        refresh(inspectDesktop: false)
        if needsOnboarding && !isRecoveringSelection { onboardingApps = initialOnboardingApps() }
        cleanup.onChange = { [weak self] in self?.reconcileReport() }
        for notification in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(workspace.notificationCenter.addObserver(forName: notification, object: nil, queue: .main) { [weak self] event in
                let invalidatesIcons = event.name == NSWorkspace.didLaunchApplicationNotification || event.name == NSWorkspace.didTerminateApplicationNotification
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if invalidatesIcons { self.runtime.invalidatePresentationCache() }
                    self.monitor.applicationStateChanged()
                    // Pending errors can resolve while the panel is closed. This
                    // checks only requested processes, without scanning Desktop.
                    if !self.monitor.isVisible { self.reconcileReport() }
                }
            })
        }
    }

    deinit {
        let notificationCenter = workspace.notificationCenter
        observers.forEach { notificationCenter.removeObserver($0) }
        cleanupTask?.cancel()
        desktopInspectionTask?.cancel()
        reportDismissTask?.cancel()
    }

    func isProtected(_ app: ManagedApplication) -> Bool { protectedKeys.contains(app.id) }
    func isRunning(_ app: SavedApplication) -> Bool { runningKeys.contains(app.id) }

    func needsOpening(_ app: SavedApplication) -> Bool {
        !isRunning(app) || (app.bundleIdentifier?.lowercased() == "com.apple.finder" && hiddenRunningKeys.contains(app.id))
    }

    func toggleOnboardingApplication(_ app: SavedApplication) {
        guard needsOnboarding, !isCleaning, !isGrantingDesktopAccess else { return }
        if onboardingApps.contains(where: { $0.id == app.id }) {
            onboardingApps.removeAll { $0.id == app.id }
        } else if let url = resolvedApplicationURL(for: app), let candidate = onboardingApplication(at: url),
                  candidate.key == app.id {
            onboardingApps.append(SavedApplication(id: app.id, name: candidate.name, bundleIdentifier: candidate.bundleIdentifier, path: candidate.path))
        }
        onboardingApps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func finishOnboarding() {
        guard needsOnboarding, !isCleaning, !isGrantingDesktopAccess else { return }
        // Suggestions remain a draft until the user explicitly finishes setup.
        // Store even an empty choice, so a restart can never reseed it.
        protectedApps = onboardingApps
        guard saveProtection() else { return }
        defaults.set(true, forKey: onboardingCompletedKey)
        needsOnboarding = false
        isRecoveringSelection = false
        refresh()
    }

    func setCleanDesktopEnabled(_ enabled: Bool) {
        guard !isCleaning, !isGrantingDesktopAccess else { return }
        if enabled && !desktopAccess.hasGrant {
            requestDesktopAccess()
            return
        }
        cleanDesktopEnabled = enabled
        defaults.set(enabled, forKey: cleanDesktopKey)
        resetReportPresentation()
        invalidateDesktopInspection()
        refresh()
    }

    func toggleProtection(_ app: ManagedApplication) {
        guard !needsOnboarding, !isCleaning else { return }
        if isProtected(app) {
            protectedApps.removeAll { $0.id == app.id }
        } else {
            protectedApps.append(SavedApplication(id: app.id, name: app.name, bundleIdentifier: app.bundleIdentifier, path: app.url?.path))
        }
        saveProtection()
    }

    func removeProtection(_ app: SavedApplication) {
        guard !needsOnboarding, !isCleaning else { return }
        protectedApps.removeAll { $0.id == app.id }
        saveProtection()
    }

    func addProtectedApplication(at url: URL) {
        guard !needsOnboarding, !isCleaning, let bundle = Bundle(url: url), url.pathExtension.lowercased() == "app",
              let key = ApplicationIdentity.key(bundleIdentifier: bundle.bundleIdentifier, path: url.path) else { return }
        guard !protectedKeys.contains(key) else { return }
        let name = ApplicationName.displayName(for: url, fallback: url.deletingPathExtension().lastPathComponent)
        protectedApps.append(SavedApplication(id: key, name: name, bundleIdentifier: bundle.bundleIdentifier, path: url.path))
        saveProtection()
    }

    func setPanelVisible(_ visible: Bool) {
        monitor.setVisible(visible)
        if !visible { invalidateDesktopInspection() }
    }

    func refresh(inspectDesktop: Bool = true) {
        let running = runtime.runningApplications()
        let records = running.map(\.record)
        let newRunningKeys = Set(records.compactMap(\.applicationKey))
        let newHiddenKeys = Set(records.filter(\.isHidden).compactMap(\.applicationKey))
        if runningKeys != newRunningKeys { runningKeys = newRunningKeys }
        if hiddenRunningKeys != newHiddenKeys { hiddenRunningKeys = newHiddenKeys }
        var byKey: [String: ManagedApplication] = [:]
        for (app, record) in zip(running, records) where policy.isEligible(record) || policy.shouldHide(record, protectedKeys: []) {
            guard let key = record.applicationKey, byKey[key] == nil else { continue }
            byKey[key] = app.row
        }
        let updated = byKey.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !applications.elementsEqual(updated, by: { $0.id == $1.id && $0.name == $1.name && $0.url == $1.url && $0.icon === $1.icon }) {
            applications = updated
        }
        reconcileReport()
        if inspectDesktop && cleanDesktopEnabled && !isCleaning {
            Task { [weak self] in
                guard let self, self.monitor.isVisible else { return }
                await self.refreshDesktopStatus()
            }
        }
    }

    /// Count exactly the same file types that cleanup accepts, without moving anything.
    /// Reuse an in-flight scan and discard results invalidated by a toggle or cleanup.
    func refreshDesktopStatus() async {
        guard !Task.isCancelled, cleanDesktopEnabled, !isCleaning, !isGrantingDesktopAccess else { return }
        if let task = desktopInspectionTask {
            await task.value
            return
        }
        let token = UUID()
        desktopInspectionToken = token
        let files = desktopFiles
        let task = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            let inspection = await files.inspect()
            guard let self, self.desktopInspectionToken == token,
                  self.cleanDesktopEnabled, !self.isCleaning else { return }
            self.desktopInspectionFailures = inspection.failures
            self.desktopInspectionAccessDenied = inspection.accessDenied
            self.desktopFileCount = inspection.eligibleCount > 0 || inspection.failures.isEmpty ? inspection.eligibleCount : nil
            self.desktopInspectionTask = nil
            self.reconcileReport()
        }
        desktopInspectionTask = task
        await task.value
    }

    private func invalidateDesktopInspection() {
        desktopInspectionToken = UUID()
        desktopInspectionTask?.cancel()
        desktopInspectionTask = nil
        desktopFileCount = nil
        desktopInspectionFailures = []
        desktopInspectionAccessDenied = false
    }

    func grantDesktopAccess() {
        guard !isCleaning, !isGrantingDesktopAccess, desktopNeedsAccess else { return }
        requestDesktopAccess()
    }

    private func requestDesktopAccess() {
        guard !isCleaning, !isGrantingDesktopAccess else { return }
        // Preserve a failed inspection as a retryable error while the option is
        // disabled. A fresh first-enable cancellation produces no error toast.
        if desktopInspectionAccessDenied {
            desktopAccessDenied = true
            desktopFailures = Array(Set(desktopFailures + desktopInspectionFailures)).sorted()
        }
        let previouslyEnabled = cleanDesktopEnabled
        isGrantingDesktopAccess = true
        cleanDesktopEnabled = false
        resetReportPresentation()
        invalidateDesktopInspection()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let granted = try await self.desktopAccess.requestGrant()
                self.isGrantingDesktopAccess = false
                if granted {
                    self.cleanDesktopEnabled = true
                    self.defaults.set(true, forKey: self.cleanDesktopKey)
                    self.desktopFailures = []
                    self.desktopAccessDenied = false
                    self.cleanup.clearDesktopFailures()
                    self.cleanupDesktopAccessDenied = false
                    self.invalidateDesktopInspection()
                } else {
                    self.cleanDesktopEnabled = previouslyEnabled
                }
                self.reconcileReport()
            } catch {
                self.isGrantingDesktopAccess = false
                self.cleanDesktopEnabled = previouslyEnabled
                self.desktopFailures = ["Could not save Desktop access. Please try again."]
                self.desktopAccessDenied = true
                self.reconcileReport()
            }
            await self.refreshDesktopStatus()
        }
    }

    func dismissReport() {
        guard !isCleaning else { return }
        if let report { dismissedReportSignature = ReportSignature(report) }
        hideReport()
    }

    private func hideReport() {
        reportDismissToken = UUID()
        reportDismissTask?.cancel()
        reportDismissTask = nil
        if report != nil { report = nil }
    }

    private func resetReportPresentation() {
        dismissedReportSignature = nil
        hideReport()
    }

    private func resetReport() {
        cleanup.reset()
        cleanupDesktopAccessDenied = false
        desktopFailures = []
        desktopAccessDenied = false
        resetReportPresentation()
    }

    func clean(_ mode: CleanupMode = .keepFavourites) {
        guard canClean(mode) else { return }
        resetReport()
        refresh(inspectDesktop: false)
        guard canClean(mode) else { return }
        let selected = protectedApps
        let shouldCleanDesktop = cleanDesktopEnabled
        isCleaning = true
        invalidateDesktopInspection()
        cleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.cleanup.clean(protectedApps: selected, cleanDesktop: shouldCleanDesktop, mode: mode)
            self.isCleaning = false
            self.cleanupTask = nil
            self.refresh(inspectDesktop: self.monitor.isVisible)
        }
    }

    private func reconcileReport() {
        guard !isCleaning, !isGrantingDesktopAccess else { return }
        let outcome = cleanup.reconcile()
        cleanupDesktopAccessDenied = outcome.desktopAccessDenied
        let allDesktopFailures = Array(Set(outcome.desktopFailures + desktopFailures + (cleanDesktopEnabled ? desktopInspectionFailures : []))).sorted()
        let anyDesktopAccessDenied = outcome.desktopAccessDenied || desktopAccessDenied || (cleanDesktopEnabled && desktopInspectionAccessDenied)
        let remaining = outcome.remaining
        let hideFailures = outcome.hideFailures
        let showFailures = outcome.showFailures
        let launchFailures = outcome.launchFailures
        guard !remaining.isEmpty || !launchFailures.isEmpty || !hideFailures.isEmpty || !showFailures.isEmpty || !allDesktopFailures.isEmpty else {
            // Keep operation tracking so a late completion can clear an earlier
            // failure silently. Successful cleanup never needs acknowledgement.
            resetReportPresentation()
            return
        }
        var details: [String] = []
        if !remaining.isEmpty { details.append("Check these apps for unsaved changes or a request to confirm quitting.") }
        if !launchFailures.isEmpty { details.append("Some selected apps could not be opened.") }
        if !hideFailures.isEmpty { details.append("Finder could not be hidden. Try cleaning again.") }
        if !showFailures.isEmpty { details.append("Finder could not be shown. Try cleaning again.") }
        if !allDesktopFailures.isEmpty { details.append(contentsOf: allDesktopFailures) }
        let detail = details.joined(separator: " ")
        let title = !hideFailures.isEmpty || !showFailures.isEmpty || !allDesktopFailures.isEmpty ? "Some items need attention" : (remaining.isEmpty ? "Some apps could not open" : (launchFailures.isEmpty ? "Some apps are still open" : "Some apps need attention"))
        showReport(CleanupReport(
            title: title,
            detail: detail,
            remaining: remaining,
            isSuccess: false,
            launchFailures: launchFailures,
            hideFailures: hideFailures,
            showFailures: showFailures,
            desktopFailures: allDesktopFailures,
            desktopAccessDenied: anyDesktopAccessDenied
        ))
    }

    private func showReport(_ candidate: CleanupReport) {
        let signature = ReportSignature(candidate)
        guard signature != dismissedReportSignature else { hideReport(); return }
        guard report.map(ReportSignature.init) != signature else { return }
        hideReport()
        dismissedReportSignature = nil
        report = candidate
        let token = UUID()
        reportDismissToken = token
        reportDismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
            guard let self, self.reportDismissToken == token,
                  self.report.map(ReportSignature.init) == signature else { return }
            self.dismissReport()
        }
    }

    private func resolvedApplicationURL(for app: SavedApplication) -> URL? { runtime.resolve(app) }

    private func record(for app: NSRunningApplication) -> RunningApplicationRecord {
        ApplicationRuntime.record(for: app)
    }

    @discardableResult
    private func saveProtection() -> Bool {
        protectedApps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        do {
            try settings.save(protectedApps)
            resetReport()
            return true
        } catch {
            // A failed write cannot turn a draft into a confirmed protection list.
            isRecoveringSelection = true
            needsOnboarding = true
            onboardingApps = []
            return false
        }
    }

    private func initialOnboardingApps() -> [SavedApplication] {
        let running = workspace.runningApplications.filter { !$0.isTerminated }
        var available = running.compactMap { app -> OnboardingApplication? in
            guard policy.isEligible(record(for: app)), let url = app.bundleURL else { return nil }
            return onboardingApplication(at: url)
        }
        for identifier in OnboardingSuggestions.fallbackBundleIdentifiers {
            if let url = workspace.urlForApplication(withBundleIdentifier: identifier),
               let app = onboardingApplication(at: url),
               app.bundleIdentifier?.lowercased() == identifier.lowercased() {
                available.append(app)
            }
        }
        return OnboardingSuggestions.select(running: running.map { record(for: $0) }, available: available, policy: policy)
            .compactMap { app in
                guard let key = app.key else { return nil }
                return SavedApplication(id: key, name: app.name, bundleIdentifier: app.bundleIdentifier, path: app.path)
            }
    }

    private func onboardingApplication(at url: URL) -> OnboardingApplication? {
        guard url.isFileURL, url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path),
              (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? NSNumber)?.boolValue != true,
              bundle.bundleIdentifier?.lowercased() != "pl.local.cleandesk" else { return nil }
        return OnboardingApplication(
            name: ApplicationName.displayName(for: url, fallback: url.deletingPathExtension().lastPathComponent),
            bundleIdentifier: bundle.bundleIdentifier,
            path: url.path
        )
    }
}
