import Foundation
import CleanDeskCore

/// Retains a particular process instance, rather than just its reusable PID.
@MainActor
protocol CleanupProcess: AnyObject {
    var record: RunningApplicationRecord { get }
    var row: ManagedApplication { get }
    var isTerminated: Bool { get }
    func currentRecord() -> RunningApplicationRecord?
    func terminate()
    func hide()
    func unhide()
}

/// AppKit and filesystem adapters supply effects; tests supply isolated fakes.
@MainActor
struct CleanupEnvironment {
    typealias LaunchCompletion = @MainActor ((any CleanupProcess)?, String?) -> Void

    let runningApplications: () -> [any CleanupProcess]
    let launch: (SavedApplication, @escaping LaunchCompletion) -> Void
    let cleanDesktop: () async -> DesktopCleanupResult
    let now: () -> Date
    let sleep: (UInt64) async throws -> Void

    init(
        runningApplications: @escaping () -> [any CleanupProcess],
        launch: @escaping (SavedApplication, @escaping LaunchCompletion) -> Void,
        cleanDesktop: @escaping () async -> DesktopCleanupResult,
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    ) {
        self.runningApplications = runningApplications
        self.launch = launch
        self.cleanDesktop = cleanDesktop
        self.now = now
        self.sleep = sleep
    }
}

struct CleanupOutcome {
    let remaining: [ManagedApplication]
    let launchFailures: [String]
    let hideFailures: [String]
    let showFailures: [String]
    let desktopFailures: [String]
    let desktopAccessDenied: Bool
}

/// Owns one cleanup session, including late completions and its remaining errors.
/// Presentation, preferences and permission prompts stay outside this coordinator.
@MainActor
final class CleanupCoordinator {
    @MainActor private struct Request {
        let process: any CleanupProcess
        let original: RunningApplicationRecord
        let row: ManagedApplication

        init(_ process: any CleanupProcess, original: RunningApplicationRecord) {
            self.process = process
            self.original = original
            row = process.row
        }

        var current: RunningApplicationRecord? {
            guard !process.isTerminated, let record = process.currentRecord(),
                  original.identifiesSameProcess(as: record) else { return nil }
            return record
        }
    }

    @MainActor private final class LaunchAttempt {
        let saved: SavedApplication
        var process: (any CleanupProcess)?
        var error: String?
        var completed = false
        var succeeded = false

        init(_ saved: SavedApplication) { self.saved = saved }
    }

    private let policy: ApplicationPolicy
    private let environment: CleanupEnvironment
    private var sessionID: UUID?
    private var requestedTermination: [Request] = []
    private var pendingHiding: [Request] = []
    private var pendingShowing: [Request] = []
    private var launchAttempts: [LaunchAttempt] = []
    private var desktopResult = DesktopCleanupResult(trashedCount: 0, failures: [])

    private(set) var isCleaning = false
    var onChange: (() -> Void)?

    init(policy: ApplicationPolicy, environment: CleanupEnvironment) {
        self.policy = policy
        self.environment = environment
    }

    /// Invalidates callbacks from the old session without undoing completed work.
    func reset() {
        sessionID = nil
        isCleaning = false
        requestedTermination = []
        pendingHiding = []
        pendingShowing = []
        launchAttempts = []
        desktopResult = DesktopCleanupResult(trashedCount: 0, failures: [])
    }

    func clearDesktopFailures() {
        desktopResult = DesktopCleanupResult(trashedCount: desktopResult.trashedCount, failures: [])
    }

    func clean(protectedApps: [SavedApplication], cleanDesktop: Bool) async {
        guard !isCleaning, !Task.isCancelled else { return }
        reset()
        let session = UUID()
        sessionID = session
        isCleaning = true
        defer {
            if sessionID == session {
                isCleaning = false
                if Task.isCancelled { sessionID = nil }
                _ = reconcile()
                onChange?()
            }
        }

        let protectedKeys = Set(protectedApps.map(\.id))
        let running = environment.runningApplications().filter { !$0.isTerminated }.map { ($0, $0.record) }
        let plan = DeskPlan(running: running.map { $0.1 }, protectedKeys: protectedKeys, policy: policy)
        let terminationPIDs = Set(plan.processesToTerminate.map(\.processIdentifier))
        let hidingPIDs = Set(plan.processesToHide.map(\.processIdentifier))
        let showingPIDs = Set(plan.processesToUnhide.map(\.processIdentifier))
        let actionPIDs = terminationPIDs.union(hidingPIDs).union(showingPIDs)
        // Reading a row can load its icon. Keep background processes in the plan's
        // running identities, but build presentation data only for actual targets.
        let snapshot = running.compactMap { process, record -> Request? in
            guard actionPIDs.contains(record.processIdentifier) else { return nil }
            return Request(process, original: record)
        }
        launchAttempts = protectedApps.filter { plan.applicationKeysToLaunch.contains($0.id) }.map(LaunchAttempt.init)

        // Finish Desktop work before quitting apps can create new saved documents.
        if cleanDesktop {
            let result = await environment.cleanDesktop()
            guard isActive(session) else { return }
            desktopResult = result
        }

        for request in snapshot where showingPIDs.contains(request.original.processIdentifier) {
            guard isActive(session) else { return }
            guard let current = request.current,
                  policy.shouldUnhide(current, protectedKeys: protectedKeys) else { continue }
            pendingShowing.append(request)
            request.process.unhide()
        }
        for attempt in launchAttempts {
            guard isActive(session) else { return }
            beginLaunch(attempt, session: session)
        }

        // System prompts may delay callbacks. Timeouts bound the action while
        // retaining attempts so a later completion can clear its error silently.
        guard await wait(session: session, timeout: 10, interval: 150_000_000, while: {
            self.resolveCompletedRequests()
            self.updateSuccessfulLaunches()
            return self.launchAttempts.contains { !$0.succeeded && $0.error == nil }
                || self.pendingShowing.contains { $0.current?.isHidden == true }
        }) else { return }
        _ = reconcile()

        for request in snapshot where terminationPIDs.contains(request.original.processIdentifier) {
            guard isActive(session) else { return }
            guard let current = request.current,
                  policy.shouldTerminate(current, protectedKeys: protectedKeys) else { continue }
            requestedTermination.append(request)
            request.process.terminate()
            // Give AppKit a chance to process save dialogs and process exits.
            await Task.yield()
        }
        guard await wait(session: session, timeout: 5, interval: 150_000_000, while: {
            self.requestedTermination.contains { $0.current != nil }
        }) else { return }

        // Finder can become active as other apps quit. Hide it last, and only if
        // the original process still has visible windows and remains unselected.
        for request in snapshot where hidingPIDs.contains(request.original.processIdentifier) {
            guard isActive(session) else { return }
            guard let current = request.current,
                  policy.shouldHide(current, protectedKeys: protectedKeys) else { continue }
            pendingHiding.append(request)
            request.process.hide()
        }
        _ = await wait(session: session, timeout: 1, interval: 100_000_000, while: {
            self.pendingHiding.contains { request in
                guard let current = request.current else { return false }
                return !current.isHidden && current.hasVisibleWindows
            }
        })
    }

    func reconcile() -> CleanupOutcome {
        resolveCompletedRequests()
        updateSuccessfulLaunches()

        var remainingByKey: [String: ManagedApplication] = [:]
        requestedTermination.forEach { remainingByKey[$0.row.id] = $0.row }
        let remaining = remainingByKey.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let launchFailures = launchAttempts.filter { !$0.succeeded }.map { attempt in
            let reason = attempt.error ?? (attempt.completed ? "the application did not stay open" : "opening is taking longer than expected")
            return "\(attempt.saved.name): \(reason)."
        }
        return CleanupOutcome(
            remaining: remaining,
            launchFailures: launchFailures,
            hideFailures: pendingHiding.map { $0.row.name },
            showFailures: pendingShowing.map { $0.row.name },
            desktopFailures: desktopResult.failures,
            desktopAccessDenied: desktopResult.accessDenied
        )
    }

    private func resolveCompletedRequests() {
        // Once an operation succeeds, later user actions must not resurrect it.
        requestedTermination.removeAll { $0.current == nil }
        pendingHiding.removeAll { request in
            guard let current = request.current else { return true }
            return current.isHidden || !current.hasVisibleWindows
        }
        pendingShowing.removeAll { request in
            guard let current = request.current else { return true }
            return !current.isHidden
        }
    }

    private func beginLaunch(_ attempt: LaunchAttempt, session: UUID) {
        updateSuccessfulLaunches()
        guard !attempt.succeeded else { return }
        environment.launch(attempt.saved) { [weak self, weak attempt] process, error in
            guard let self, let attempt, self.sessionID == session else { return }
            attempt.completed = true
            if let process, process.record.applicationKey == attempt.saved.id {
                attempt.process = process
            } else {
                attempt.error = error ?? "macOS did not confirm that the application opened"
            }
            self.updateSuccessfulLaunches()
            self.onChange?()
        }
    }

    private func updateSuccessfulLaunches() {
        guard launchAttempts.contains(where: { !$0.succeeded }) else { return }
        let runningKeys = Set(environment.runningApplications().filter { !$0.isTerminated }.compactMap { $0.record.applicationKey })
        for attempt in launchAttempts where !attempt.succeeded {
            if runningKeys.contains(attempt.saved.id) {
                attempt.succeeded = true
            } else if let process = attempt.process, !process.isTerminated,
                      process.record.applicationKey == attempt.saved.id {
                attempt.succeeded = true
            }
        }
    }

    private func isActive(_ session: UUID) -> Bool {
        sessionID == session && !Task.isCancelled
    }

    private func wait(session: UUID, timeout: TimeInterval, interval: UInt64, while pending: () -> Bool) async -> Bool {
        let deadline = environment.now().addingTimeInterval(timeout)
        while isActive(session), environment.now() < deadline, pending() {
            do { try await environment.sleep(interval) } catch { return false }
        }
        return isActive(session)
    }
}
