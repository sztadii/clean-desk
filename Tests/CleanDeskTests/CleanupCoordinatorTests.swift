import AppKit
import XCTest
import CleanDeskCore
@testable import CleanDesk

@MainActor
final class CleanupCoordinatorTests: XCTestCase {
    func testCleanAllClosesFavouritesWithoutLaunchingMissingFavourites() async {
        let world = CleanupWorld()
        let favourite = world.add("Browser", pid: 12)
        let editor = world.add("Editor", pid: 10)
        let coordinator = world.coordinator()

        await coordinator.clean(
            protectedApps: [favourite.saved, world.saved("Missing")],
            cleanDesktop: true,
            mode: .closeAll
        )

        XCTAssertEqual(world.events.first, "desktop")
        XCTAssertEqual(Set(world.events.dropFirst()), ["quit:Browser", "quit:Editor"])
        XCTAssertTrue(favourite.isTerminated)
        XCTAssertTrue(editor.isTerminated)
        assertSuccessful(coordinator.reconcile())
    }

    func testCleanNonfavouriteKeepsRunningFavouriteAndCleansDesktop() async {
        let world = CleanupWorld()
        let favourite = world.add("Browser", pid: 12)
        let editor = world.add("Editor", pid: 10)
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [favourite.saved], cleanDesktop: true)

        XCTAssertEqual(world.events, ["desktop", "quit:Editor"])
        XCTAssertFalse(favourite.isTerminated)
        XCTAssertTrue(editor.isTerminated)
        assertSuccessful(coordinator.reconcile())
    }

    func testFullCleanupOrdersDesktopLaunchQuitAndFinderHide() async {
        let world = CleanupWorld()
        let editor = world.add("Editor", pid: 10)
        let finder = world.add("Finder", pid: 11, bundle: "com.apple.finder", visible: true)
        let selected = world.saved("Browser")
        world.onLaunch = { saved, completion in
            completion(world.add(saved.name, pid: 12), nil)
        }
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [selected], cleanDesktop: true)

        XCTAssertEqual(world.events, ["desktop", "launch:Browser", "quit:Editor", "hide:Finder"])
        XCTAssertTrue(editor.isTerminated)
        XCTAssertTrue(finder.hidden)
        XCTAssertFalse(finder.isTerminated)
        XCTAssertFalse(coordinator.isCleaning)
        assertSuccessful(coordinator.reconcile())
    }

    func testSelectedFinderIsUnhiddenBeforeOtherAppsQuit() async {
        let world = CleanupWorld()
        let finder = world.add("Finder", pid: 11, bundle: "com.apple.finder", hidden: true)
        _ = world.add("Editor", pid: 10)
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [finder.saved], cleanDesktop: false)

        XCTAssertEqual(world.events, ["unhide:Finder", "quit:Editor"])
        XCTAssertFalse(finder.hidden)
        assertSuccessful(coordinator.reconcile())
        finder.hidden = true
        assertSuccessful(coordinator.reconcile())
    }

    func testQuitRefusalRemainsAnErrorWithoutForceQuitOrBlockingFinder() async {
        let world = CleanupWorld()
        let editor = world.add("Unsaved", pid: 10)
        editor.acceptsQuit = false
        let finder = world.add("Finder", pid: 11, bundle: "com.apple.finder", visible: true)
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [], cleanDesktop: false)

        XCTAssertEqual(world.events, ["quit:Unsaved", "hide:Finder"])
        XCTAssertEqual(coordinator.reconcile().remaining.map(\.name), ["Unsaved"])
        XCTAssertFalse(editor.isTerminated)
        XCTAssertTrue(finder.hidden)
        XCTAssertGreaterThanOrEqual(world.elapsed, 5)
        XCTAssertLessThan(world.elapsed, 5.2)
        editor.isTerminated = true
        assertSuccessful(coordinator.reconcile())
    }

    func testDelayedLaunchCompletesBeforeQuitAndNeverBecomesATarget() async {
        let world = CleanupWorld()
        _ = world.add("Editor", pid: 10)
        var completion: CleanupEnvironment.LaunchCompletion?
        world.onLaunch = { _, callback in completion = callback }
        world.onSleep = {
            if world.elapsed >= 0.3, let callback = completion {
                completion = nil
                callback(world.add("Browser", pid: 12), nil)
            }
        }
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [world.saved("Browser")], cleanDesktop: false)

        XCTAssertEqual(world.events, ["launch:Browser", "quit:Editor"])
        XCTAssertGreaterThanOrEqual(world.elapsed, 0.3)
        XCTAssertLessThan(world.elapsed, 1)
        XCTAssertFalse(world.processes.first { $0.name == "Browser" }!.isTerminated)
        assertSuccessful(coordinator.reconcile())
    }

    func testLateLaunchClearsTimeoutAndClosingItLaterDoesNotRestoreError() async {
        let world = CleanupWorld()
        var completion: CleanupEnvironment.LaunchCompletion?
        world.onLaunch = { _, callback in completion = callback }
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [world.saved("Browser")], cleanDesktop: false)

        XCTAssertEqual(coordinator.reconcile().launchFailures, ["Browser: opening is taking longer than expected."])
        XCTAssertGreaterThanOrEqual(world.elapsed, 10)
        XCTAssertLessThan(world.elapsed, 10.2)
        let browser = world.add("Browser", pid: 12)
        completion?(browser, nil)
        assertSuccessful(coordinator.reconcile())
        browser.isTerminated = true
        assertSuccessful(coordinator.reconcile())
    }

    func testLaunchFailureDoesNotPreventOtherApplicationsFromClosing() async {
        let world = CleanupWorld()
        _ = world.add("Editor", pid: 10)
        world.onLaunch = { _, completion in completion(nil, "the installed application could not be found") }
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [world.saved("Browser")], cleanDesktop: false)

        XCTAssertEqual(world.events, ["launch:Browser", "quit:Editor"])
        XCTAssertEqual(coordinator.reconcile().launchFailures, ["Browser: the installed application could not be found."])
        XCTAssertEqual(world.elapsed, 0)
    }

    func testDesktopPermissionLossAndPartialErrorsRemainAlongsideAppErrors() async {
        let world = CleanupWorld()
        let editor = world.add("Unsaved", pid: 10)
        editor.acceptsQuit = false
        world.desktopResult = DesktopCleanupResult(
            trashedCount: 2,
            failures: ["macOS denied access to one file.", "Another file changed during cleanup."],
            accessDenied: true
        )
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [], cleanDesktop: true)

        let result = coordinator.reconcile()
        XCTAssertEqual(world.events, ["desktop", "quit:Unsaved"])
        XCTAssertEqual(result.remaining.map(\.name), ["Unsaved"])
        XCTAssertEqual(result.desktopFailures, world.desktopResult.failures)
        XCTAssertTrue(result.desktopAccessDenied)

        coordinator.clearDesktopFailures()
        let recovered = coordinator.reconcile()
        XCTAssertTrue(recovered.desktopFailures.isEmpty)
        XCTAssertFalse(recovered.desktopAccessDenied)
        XCTAssertEqual(recovered.remaining.map(\.name), ["Unsaved"])
    }

    func testProcessReplacedDuringDesktopCleanupIsNeverTerminated() async {
        let world = CleanupWorld()
        let original = world.add("Editor", pid: 10)
        world.onDesktop = {
            original.replacement = RunningApplicationRecord(
                processIdentifier: 10, bundleIdentifier: original.bundleIdentifier,
                path: original.path, isRegular: true, launchDate: Date(timeIntervalSince1970: 999)
            )
        }
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [], cleanDesktop: true)

        XCTAssertEqual(world.events, ["desktop"])
        XCTAssertFalse(original.isTerminated)
        assertSuccessful(coordinator.reconcile())
    }

    func testUnselectedAppLaunchedAfterSnapshotIsNotClosed() async {
        let world = CleanupWorld()
        _ = world.add("Editor", pid: 10)
        var lateApp: FakeCleanupProcess?
        world.onDesktop = { lateApp = world.add("New app", pid: 13) }
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [], cleanDesktop: true)

        XCTAssertEqual(world.events, ["desktop", "quit:Editor"])
        XCTAssertFalse(lateApp!.isTerminated)
        assertSuccessful(coordinator.reconcile())
    }

    func testSuccessfulFinderHideDoesNotBecomeAnErrorWhenUserReopensIt() async {
        let world = CleanupWorld()
        let finder = world.add("Finder", pid: 11, bundle: "com.apple.finder", visible: true)
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [], cleanDesktop: false)

        assertSuccessful(coordinator.reconcile())
        finder.hidden = false
        finder.visible = true
        assertSuccessful(coordinator.reconcile())
        XCTAssertEqual(world.events, ["hide:Finder"])
    }

    func testFinderFailureResolvesWhenItsWindowsAreClosed() async {
        let world = CleanupWorld()
        let finder = world.add("Finder", pid: 11, bundle: "com.apple.finder", visible: true)
        finder.acceptsHide = false
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [], cleanDesktop: false)

        XCTAssertEqual(coordinator.reconcile().hideFailures, ["Finder"])
        finder.visible = false
        assertSuccessful(coordinator.reconcile())
        finder.visible = true
        assertSuccessful(coordinator.reconcile())
    }

    func testResetIgnoresOldLaunchCallbacksAndStopsRemainingActions() async {
        let world = CleanupWorld()
        _ = world.add("Editor", pid: 10)
        var completion: CleanupEnvironment.LaunchCompletion?
        world.onLaunch = { _, callback in completion = callback }
        let coordinator = world.coordinator()
        world.onSleep = { coordinator.reset() }

        await coordinator.clean(protectedApps: [world.saved("Browser")], cleanDesktop: false)
        completion?(nil, "stale error")

        XCTAssertEqual(world.events, ["launch:Browser"])
        XCTAssertFalse(coordinator.isCleaning)
        assertSuccessful(coordinator.reconcile())
    }

    func testCancellationDuringLaunchWaitNeverQuitsOtherApps() async {
        let world = CleanupWorld()
        _ = world.add("Editor", pid: 10)
        var completion: CleanupEnvironment.LaunchCompletion?
        world.onLaunch = { _, callback in completion = callback }
        let coordinator = world.coordinator()
        let task = Task { await coordinator.clean(protectedApps: [world.saved("Browser")], cleanDesktop: false) }
        world.onSleep = { task.cancel() }

        await task.value
        let before = coordinator.reconcile().launchFailures
        completion?(nil, "stale error")

        XCTAssertEqual(world.events, ["launch:Browser"])
        XCTAssertFalse(coordinator.isCleaning)
        XCTAssertEqual(coordinator.reconcile().launchFailures, before)
    }

    func testSkippedDesktopAndAlreadyOpenProtectedAppsPerformNoActions() async {
        let world = CleanupWorld()
        let browser = world.add("Browser", pid: 12)
        let coordinator = world.coordinator()

        await coordinator.clean(protectedApps: [browser.saved], cleanDesktop: false)

        XCTAssertTrue(world.events.isEmpty)
        XCTAssertEqual(world.elapsed, 0)
        assertSuccessful(coordinator.reconcile())
    }

    private func assertSuccessful(_ result: CleanupOutcome, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.remaining.isEmpty, file: file, line: line)
        XCTAssertTrue(result.launchFailures.isEmpty, file: file, line: line)
        XCTAssertTrue(result.hideFailures.isEmpty, file: file, line: line)
        XCTAssertTrue(result.showFailures.isEmpty, file: file, line: line)
        XCTAssertTrue(result.desktopFailures.isEmpty, file: file, line: line)
        XCTAssertFalse(result.desktopAccessDenied, file: file, line: line)
    }
}

@MainActor
private final class CleanupWorld {
    var processes: [FakeCleanupProcess] = []
    var events: [String] = []
    var elapsed: TimeInterval = 0
    var onLaunch: ((SavedApplication, @escaping CleanupEnvironment.LaunchCompletion) -> Void)?
    var onSleep: (() -> Void)?
    var onDesktop: (() -> Void)?
    var desktopResult = DesktopCleanupResult(trashedCount: 0, failures: [])

    func add(_ name: String, pid: Int32, bundle: String? = nil, hidden: Bool = false, visible: Bool = false) -> FakeCleanupProcess {
        let process = FakeCleanupProcess(name: name, pid: pid, bundle: bundle ?? "test." + name.lowercased(), hidden: hidden, visible: visible)
        process.onEvent = { [weak self] in self?.events.append($0) }
        processes.append(process)
        return process
    }

    func saved(_ name: String) -> SavedApplication {
        let identifier = "test." + name.lowercased()
        return SavedApplication(id: "bundle:" + identifier, name: name, bundleIdentifier: identifier, path: "/Applications/\(name).app")
    }

    func coordinator() -> CleanupCoordinator {
        let environment = CleanupEnvironment(
            runningApplications: { self.processes.filter { !$0.isTerminated } },
            launch: { saved, completion in
                self.events.append("launch:" + saved.name)
                self.onLaunch?(saved, completion)
            },
            cleanDesktop: {
                self.events.append("desktop")
                self.onDesktop?()
                return self.desktopResult
            },
            now: { Date(timeIntervalSince1970: self.elapsed) },
            sleep: { nanoseconds in
                self.elapsed += TimeInterval(nanoseconds) / 1_000_000_000
                self.onSleep?()
                try Task.checkCancellation()
                await Task.yield()
            }
        )
        return CleanupCoordinator(policy: ApplicationPolicy(ownProcessIdentifier: 1, ownBundleIdentifier: "test.cleandesk"), environment: environment)
    }
}

@MainActor
private final class FakeCleanupProcess: CleanupProcess {
    let name: String
    let pid: Int32
    let bundleIdentifier: String
    var path: String { "/Applications/\(name).app" }
    var hidden: Bool
    var visible: Bool
    var isTerminated = false
    var acceptsQuit = true
    var acceptsHide = true
    var acceptsUnhide = true
    var replacement: RunningApplicationRecord?
    var onEvent: ((String) -> Void)?

    init(name: String, pid: Int32, bundle: String, hidden: Bool, visible: Bool) {
        self.name = name
        self.pid = pid
        bundleIdentifier = bundle
        self.hidden = hidden
        self.visible = visible
    }

    var saved: SavedApplication {
        SavedApplication(id: "bundle:" + bundleIdentifier.lowercased(), name: name, bundleIdentifier: bundleIdentifier, path: path)
    }

    var row: ManagedApplication {
        ManagedApplication(id: saved.id, name: name, icon: NSImage(size: NSSize(width: 32, height: 32)), bundleIdentifier: bundleIdentifier, url: URL(fileURLWithPath: path))
    }

    var record: RunningApplicationRecord {
        RunningApplicationRecord(
            processIdentifier: pid, bundleIdentifier: bundleIdentifier, path: path, isRegular: true,
            launchDate: Date(timeIntervalSince1970: 1), isHidden: hidden, hasVisibleWindows: visible
        )
    }

    func currentRecord() -> RunningApplicationRecord? { isTerminated ? nil : (replacement ?? record) }
    func terminate() {
        onEvent?("quit:" + name)
        if acceptsQuit { isTerminated = true }
    }
    func hide() {
        onEvent?("hide:" + name)
        if acceptsHide { hidden = true }
    }
    func unhide() {
        onEvent?("unhide:" + name)
        if acceptsUnhide { hidden = false }
    }
}
