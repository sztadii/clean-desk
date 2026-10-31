import XCTest
@testable import CleanDesk

final class OnboardingStoreTests: XCTestCase {
    @MainActor
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "CleanDeskTests.Onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @MainActor
    func testFirstLaunchBlocksCleanupAndDoesNotSaveDraftSuggestions() async throws {
        try withDefaults { defaults in
            let oldChoice = SavedApplication(id: "bundle:test.old-selection", name: "Old selection", bundleIdentifier: "test.old-selection", path: "/Missing/Old.app")
            let oldData = try JSONEncoder().encode([oldChoice])
            defaults.set(oldData, forKey: "protectedApplications.v1")
            let store = AppStore(defaults: defaults)
            XCTAssertTrue(store.needsOnboarding)
            XCTAssertFalse(store.canClean(.keepFavourites))
            XCTAssertFalse(store.canClean(.closeAll))
            for mode in CleanupMode.allCases {
                XCTAssertEqual(store.cleanupDisabledReason(mode), "Finish setup first")
            }
            XCTAssertFalse(store.onboardingApps.contains { $0.id == oldChoice.id })
            XCTAssertEqual(defaults.data(forKey: "protectedApplications.v1"), oldData)

            store.clean()
            XCTAssertFalse(store.isCleaning)
            XCTAssertEqual(defaults.data(forKey: "protectedApplications.v1"), oldData)
            XCTAssertFalse(defaults.bool(forKey: "onboardingCompleted.v1"))
        }
    }

    @MainActor
    func testRemovingAllSuggestionsPersistsAnExplicitEmptyChoiceOnFinish() async throws {
        try withDefaults { defaults in
            let store = AppStore(defaults: defaults)
            for app in store.onboardingApps { store.toggleOnboardingApplication(app) }
            XCTAssertTrue(store.onboardingApps.isEmpty)
            XCTAssertNil(defaults.data(forKey: "protectedApplications.v1"))
            store.finishOnboarding()
            XCTAssertFalse(store.needsOnboarding)
            XCTAssertTrue(store.protectedApps.isEmpty)
            XCTAssertTrue(defaults.bool(forKey: "onboardingCompleted.v1"))
            let saved = try JSONDecoder().decode([SavedApplication].self, from: XCTUnwrap(defaults.data(forKey: "protectedApplications.v1")))
            XCTAssertTrue(saved.isEmpty)

            let relaunched = AppStore(defaults: defaults)
            XCTAssertFalse(relaunched.needsOnboarding)
            XCTAssertTrue(relaunched.protectedApps.isEmpty)
            XCTAssertTrue(relaunched.onboardingApps.isEmpty)
        }
    }

    @MainActor
    func testFinishingSavesExactlyTheDraftAndRelaunchDoesNotSuggestOtherApps() async throws {
        try withDefaults { defaults in
            let store = AppStore(defaults: defaults)
            let draftIDs = store.onboardingApps.map(\.id)
            store.finishOnboarding()
            XCTAssertEqual(store.protectedApps.map(\.id).sorted(), draftIDs.sorted())
            let data = try XCTUnwrap(defaults.data(forKey: "protectedApplications.v1"))
            let saved = try JSONDecoder().decode([SavedApplication].self, from: data)
            XCTAssertEqual(saved.map(\.id).sorted(), draftIDs.sorted())

            let relaunched = AppStore(defaults: defaults)
            XCTAssertFalse(relaunched.needsOnboarding)
            XCTAssertEqual(relaunched.protectedApps.map(\.id), saved.map(\.id))
            XCTAssertTrue(relaunched.onboardingApps.isEmpty)
            relaunched.finishOnboarding()
            XCTAssertEqual(defaults.data(forKey: "protectedApplications.v1"), data)
        }
    }

    @MainActor
    func testAbandonedOnboardingReturnsOnRelaunchWithoutCommittingDraft() async {
        withDefaults { defaults in
            let store = AppStore(defaults: defaults)
            for app in store.onboardingApps { store.toggleOnboardingApplication(app) }
            let relaunched = AppStore(defaults: defaults)
            XCTAssertTrue(relaunched.needsOnboarding)
            XCTAssertFalse(relaunched.canClean(.keepFavourites))
            XCTAssertFalse(relaunched.canClean(.closeAll))
            XCTAssertNil(defaults.data(forKey: "protectedApplications.v1"))
            XCTAssertFalse(defaults.bool(forKey: "onboardingCompleted.v1"))
        }
    }

    @MainActor
    func testManuallyChosenInstalledAppStaysDraftUntilFinishAndSurvivesRelaunch() async throws {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("CleanDeskOnboarding-\(UUID().uuidString)")
        let appURL = fixtureRoot.appendingPathComponent("Custom.app")
        let contentsURL = appURL.appendingPathComponent("Contents")
        let executableURL = contentsURL.appendingPathComponent("MacOS/Custom")
        try FileManager.default.createDirectory(at: executableURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let identifier = "test.cleandesk.onboarding.\(UUID().uuidString.lowercased())"
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Custom",
            "CFBundleExecutable": "Custom",
            "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contentsURL.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        let choice = SavedApplication(id: "bundle:\(identifier)", name: "Custom", bundleIdentifier: identifier, path: appURL.path)

        try withDefaults { defaults in
            let store = AppStore(defaults: defaults)
            for app in store.onboardingApps { store.toggleOnboardingApplication(app) }
            store.toggleOnboardingApplication(choice)
            XCTAssertEqual(store.onboardingApps.map(\.id), [choice.id])
            XCTAssertTrue(store.protectedApps.isEmpty)
            XCTAssertNil(defaults.data(forKey: "protectedApplications.v1"))
            XCTAssertFalse(store.canClean(.keepFavourites))
            XCTAssertFalse(store.canClean(.closeAll))

            store.finishOnboarding()
            let saved = try JSONDecoder().decode([SavedApplication].self, from: XCTUnwrap(defaults.data(forKey: "protectedApplications.v1")))
            XCTAssertEqual(saved.map(\.id), [choice.id])
            let relaunched = AppStore(defaults: defaults)
            XCTAssertFalse(relaunched.needsOnboarding)
            XCTAssertEqual(relaunched.protectedApps.map(\.id), [choice.id])
            XCTAssertEqual(relaunched.launchCount, 1)
        }
    }
}
