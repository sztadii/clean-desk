import XCTest
@testable import CleanDeskCore

final class ApplicationPolicyTests: XCTestCase {
    private let policy = ApplicationPolicy(ownProcessIdentifier: 100, ownBundleIdentifier: "local.cleandesk.app")

    private func app(_ pid: Int32 = 200, bundle: String? = "example.editor", path: String? = "/Applications/Editor.app", regular: Bool = true, date: Date? = Date(timeIntervalSince1970: 1), hidden: Bool = false, visibleWindows: Bool = false) -> RunningApplicationRecord {
        RunningApplicationRecord(processIdentifier: pid, bundleIdentifier: bundle, path: path, isRegular: regular, launchDate: date, isHidden: hidden, hasVisibleWindows: visibleWindows)
    }

    func testOnlyNormalUserAppsAreEligible() {
        XCTAssertTrue(policy.isEligible(app()))
        XCTAssertFalse(policy.isEligible(app(regular: false)))
        XCTAssertFalse(policy.isEligible(app(100)))
        XCTAssertFalse(policy.isEligible(app(bundle: "local.cleandesk.app")))
        XCTAssertFalse(policy.isEligible(app(bundle: "com.apple.finder")))
        XCTAssertFalse(policy.isEligible(app(bundle: nil, path: nil)))
    }

    func testProtectedBundleStaysProtectedAcrossPathsAndRestarts() {
        let key = ApplicationIdentity.key(bundleIdentifier: "com.jetbrains.WebStorm", path: "/old/WebStorm.app")!
        let relocated = app(201, bundle: "com.jetbrains.webstorm", path: "/new/WebStorm.app")
        XCTAssertFalse(policy.shouldTerminate(relocated, protectedKeys: [key]))
        XCTAssertTrue(policy.shouldTerminate(app(), protectedKeys: [key]))
    }

    func testMissingBundleIdentifierUsesNormalizedPath() {
        let key = ApplicationIdentity.key(bundleIdentifier: nil, path: "/Applications/../Applications/Custom.app")!
        let custom = app(bundle: nil, path: "/Applications/Custom.app")
        XCTAssertEqual(key, custom.applicationKey)
        XCTAssertFalse(policy.shouldTerminate(custom, protectedKeys: [key]))
        XCTAssertNil(ApplicationIdentity.key(bundleIdentifier: "  ", path: nil))
    }

    func testEveryInstanceIsKeptInCleanupSnapshot() {
        let a = app(201)
        let b = app(202)
        let protected = app(203, bundle: "example.browser")
        let helper = app(204, bundle: "example.editor.helper", regular: false)
        XCTAssertEqual(policy.candidates(from: [a, b, protected, helper], protectedKeys: [protected.applicationKey!]), [a, b])
    }

    func testPIDReuseOrRestartCannotMatchOriginalProcess() {
        let original = app(200)
        XCTAssertTrue(original.identifiesSameProcess(as: app(200)))
        XCTAssertFalse(original.identifiesSameProcess(as: app(201)))
        XCTAssertFalse(original.identifiesSameProcess(as: app(200, bundle: "example.other")))
        XCTAssertFalse(original.identifiesSameProcess(as: app(200, date: Date(timeIntervalSince1970: 2))))
        XCTAssertFalse(original.identifiesSameProcess(as: app(200, date: nil)))
    }

    func testProtectionIsRecheckedBeforeTermination() {
        let candidate = app()
        let initial = policy.candidates(from: [candidate], protectedKeys: [])
        XCTAssertEqual(initial.count, 1)
        XCTAssertFalse(policy.shouldTerminate(initial[0], protectedKeys: [candidate.applicationKey!]))
        XCTAssertFalse(policy.shouldTerminate(app(regular: false), protectedKeys: []))
    }

    func testPlanOpensOnlyMissingSavedChoicesAndClosesUnselectedApps() {
        let runningEditor = app(201, bundle: "example.editor")
        let selectedBrowser = app(202, bundle: "example.browser")
        let selectedBackgroundApp = app(203, bundle: "example.utility", regular: false)
        let missingChoice = "bundle:example.missing"
        let plan = DeskPlan(
            running: [runningEditor, selectedBrowser, selectedBackgroundApp],
            protectedKeys: [selectedBrowser.applicationKey!, selectedBackgroundApp.applicationKey!, missingChoice],
            policy: policy
        )
        XCTAssertEqual(plan.applicationKeysToLaunch, [missingChoice])
        XCTAssertEqual(plan.processesToTerminate, [runningEditor])
    }

    func testPlanWithNoSavedChoicesNeverLaunchesAnything() {
        let running = app()
        let plan = DeskPlan(running: [running], protectedKeys: [], policy: policy)
        XCTAssertTrue(plan.applicationKeysToLaunch.isEmpty)
        XCTAssertEqual(plan.processesToTerminate, [running])
    }

    func testPlanCanOpenSelectedAppsWhenThereIsNothingToClose() {
        let desired: Set<String> = ["bundle:example.editor", "bundle:example.browser"]
        let plan = DeskPlan(running: [], protectedKeys: desired, policy: policy)
        XCTAssertEqual(plan.applicationKeysToLaunch, desired)
        XCTAssertTrue(plan.processesToTerminate.isEmpty)
    }

    func testPlanRecognizesMovedBundlesAndPathOnlyRunningApps() {
        let moved = app(201, bundle: "example.editor", path: "/New/Editor.app")
        let pathOnly = app(202, bundle: nil, path: "/Applications/Custom.app")
        let savedEditor = ApplicationIdentity.key(bundleIdentifier: "example.editor", path: "/Old/Editor.app")!
        let savedCustom = ApplicationIdentity.key(bundleIdentifier: nil, path: "/Applications/../Applications/Custom.app")!
        let plan = DeskPlan(running: [moved, pathOnly], protectedKeys: [savedEditor, savedCustom], policy: policy)
        XCTAssertTrue(plan.applicationKeysToLaunch.isEmpty)
        XCTAssertTrue(plan.processesToTerminate.isEmpty)
    }

    func testVisibleFinderIsHiddenWhileOtherAppsAreTerminated() {
        let finder = app(201, bundle: "com.apple.finder", visibleWindows: true)
        let editor = app(202, visibleWindows: true)
        let plan = DeskPlan(running: [finder, editor], protectedKeys: [], policy: policy)

        XCTAssertFalse(policy.isEligible(finder))
        XCTAssertFalse(policy.shouldTerminate(finder, protectedKeys: []))
        XCTAssertEqual(plan.processesToHide, [finder])
        XCTAssertEqual(plan.processesToTerminate, [editor])
    }

    func testFinderAloneCanCreateAHideOnlyPlan() {
        let finder = app(bundle: "com.apple.finder", visibleWindows: true)
        let plan = DeskPlan(running: [finder], protectedKeys: [], policy: policy)

        XCTAssertEqual(plan.processesToHide, [finder])
        XCTAssertTrue(plan.processesToTerminate.isEmpty)
        XCTAssertTrue(plan.applicationKeysToLaunch.isEmpty)
    }

    func testHiddenFinderAndFinderWithoutVisibleWindowsDoNotCreateWork() {
        for finder in [
            app(bundle: "com.apple.finder", hidden: true, visibleWindows: true),
            app(bundle: "com.apple.finder", hidden: false, visibleWindows: false),
            app(bundle: "com.apple.finder", hidden: true, visibleWindows: false)
        ] {
            let plan = DeskPlan(running: [finder], protectedKeys: [], policy: policy)
            XCTAssertTrue(plan.processesToHide.isEmpty)
            XCTAssertTrue(plan.processesToTerminate.isEmpty)
            XCTAssertTrue(plan.applicationKeysToLaunch.isEmpty)
        }
    }

    func testProtectedFinderIsNeitherHiddenNorTerminated() {
        let finder = app(bundle: "com.apple.Finder", visibleWindows: true)
        let plan = DeskPlan(running: [finder], protectedKeys: ["bundle:com.apple.finder"], policy: policy)

        XCTAssertTrue(plan.processesToHide.isEmpty)
        XCTAssertTrue(plan.processesToUnhide.isEmpty)
        XCTAssertTrue(plan.processesToTerminate.isEmpty)
        XCTAssertTrue(plan.applicationKeysToLaunch.isEmpty)
    }

    func testSelectedHiddenFinderIsRestoredWithoutLaunchingOrTerminatingIt() {
        let finder = app(bundle: "com.apple.Finder", hidden: true, visibleWindows: false)
        let plan = DeskPlan(running: [finder], protectedKeys: ["bundle:com.apple.finder"], policy: policy)

        XCTAssertEqual(plan.processesToUnhide, [finder])
        XCTAssertTrue(plan.processesToHide.isEmpty)
        XCTAssertTrue(plan.processesToTerminate.isEmpty)
        XCTAssertTrue(plan.applicationKeysToLaunch.isEmpty)
        XCTAssertFalse(policy.shouldTerminate(finder, protectedKeys: []))
    }

    func testUnselectedHiddenFinderRemainsHiddenWithoutCreatingWork() {
        let finder = app(bundle: "com.apple.finder", hidden: true, visibleWindows: false)
        let plan = DeskPlan(running: [finder], protectedKeys: [], policy: policy)

        XCTAssertTrue(plan.processesToUnhide.isEmpty)
        XCTAssertTrue(plan.processesToHide.isEmpty)
        XCTAssertTrue(plan.processesToTerminate.isEmpty)
        XCTAssertTrue(plan.applicationKeysToLaunch.isEmpty)
    }

    func testUnhidingDoesNotAffectOtherSelectedAppsOrBackgroundHelpers() {
        let editor = app(201, hidden: true)
        let helper = app(202, bundle: "com.apple.finder", regular: false, hidden: true)
        let ownPID = app(100, bundle: "com.apple.finder", hidden: true)
        let finderHelper = app(203, bundle: "com.apple.finder.helper", hidden: true)
        let records = [editor, helper, ownPID, finderHelper]
        let selected = Set(records.compactMap(\.applicationKey))
        let plan = DeskPlan(running: records, protectedKeys: selected, policy: policy)

        XCTAssertTrue(plan.processesToUnhide.isEmpty)
        let finderPolicy = ApplicationPolicy(ownProcessIdentifier: 100, ownBundleIdentifier: "com.apple.Finder")
        XCTAssertFalse(finderPolicy.shouldUnhide(app(bundle: "com.apple.finder", hidden: true), protectedKeys: ["bundle:com.apple.finder"]))
    }

    func testHidingNeverTargetsOwnProcessOrBackgroundHelpers() {
        XCTAssertFalse(policy.shouldHide(app(100, bundle: "com.apple.finder", visibleWindows: true), protectedKeys: []))
        XCTAssertFalse(policy.shouldHide(app(bundle: "com.apple.finder", regular: false, visibleWindows: true), protectedKeys: []))
        XCTAssertFalse(policy.shouldHide(app(bundle: "com.apple.finder.helper", visibleWindows: true), protectedKeys: []))
        XCTAssertFalse(policy.shouldHide(app(visibleWindows: true), protectedKeys: []))
        let finderPolicy = ApplicationPolicy(ownProcessIdentifier: 100, ownBundleIdentifier: "com.apple.Finder")
        XCTAssertFalse(finderPolicy.shouldHide(app(bundle: "com.apple.finder", visibleWindows: true), protectedKeys: []))
    }

    func testVisibilityChangesDoNotChangeTheCapturedProcessIdentity() {
        let original = app(bundle: "com.apple.finder", visibleWindows: true)
        let hidden = app(bundle: "com.apple.finder", hidden: true, visibleWindows: false)
        let restarted = app(bundle: "com.apple.finder", date: Date(timeIntervalSince1970: 2), hidden: true)

        XCTAssertTrue(original.identifiesSameProcess(as: hidden))
        XCTAssertFalse(original.identifiesSameProcess(as: restarted))
    }
}
