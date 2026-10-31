import XCTest
@testable import CleanDesk

final class SettingsRecoveryTests: XCTestCase {
    private let selectionKey = "protectedApplications.v1"
    private let onboardingKey = "onboardingCompleted.v1"

    @MainActor
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "CleanDeskTests.SettingsRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @MainActor
    func testCorruptCompletedSelectionBlocksCleanupWithoutReplacingOriginalData() async {
        withDefaults { defaults in
            let original = Data("broken selection".utf8)
            defaults.set(original, forKey: selectionKey)
            defaults.set(true, forKey: onboardingKey)

            let store = AppStore(defaults: defaults)
            XCTAssertTrue(store.needsOnboarding)
            XCTAssertTrue(store.isRecoveringSelection)
            XCTAssertTrue(store.protectedApps.isEmpty)
            XCTAssertTrue(store.onboardingApps.isEmpty)
            XCTAssertFalse(store.canClean(.keepFavourites))
            XCTAssertFalse(store.canClean(.closeAll))
            for mode in CleanupMode.allCases {
                XCTAssertEqual(store.cleanupDisabledReason(mode), "Save your favourites first")
            }

            store.clean()
            XCTAssertFalse(store.isCleaning)
            XCTAssertEqual(defaults.data(forKey: selectionKey), original)
            XCTAssertTrue(defaults.bool(forKey: onboardingKey))
        }
    }

    @MainActor
    func testMissingCompletedSelectionRequiresExplicitRecovery() async {
        withDefaults { defaults in
            defaults.set(true, forKey: onboardingKey)
            let store = AppStore(defaults: defaults)
            XCTAssertTrue(store.needsOnboarding)
            XCTAssertTrue(store.isRecoveringSelection)
            XCTAssertTrue(store.onboardingApps.isEmpty)
            XCTAssertFalse(store.canClean(.keepFavourites))
            XCTAssertFalse(store.canClean(.closeAll))
            store.clean()
            XCTAssertFalse(store.isCleaning)
            XCTAssertNil(defaults.object(forKey: selectionKey))
        }
    }

    @MainActor
    func testInvalidSelectionRequiresRecoveryEvenBeforeOnboardingWasCompleted() async {
        withDefaults { defaults in
            defaults.set("wrong storage type", forKey: selectionKey)
            let store = AppStore(defaults: defaults)
            XCTAssertTrue(store.isRecoveringSelection)
            XCTAssertTrue(store.needsOnboarding)
            XCTAssertTrue(store.onboardingApps.isEmpty)
            XCTAssertFalse(store.canClean(.keepFavourites))
            XCTAssertFalse(store.canClean(.closeAll))
            XCTAssertEqual(defaults.string(forKey: selectionKey), "wrong storage type")
            XCTAssertFalse(defaults.bool(forKey: onboardingKey))
        }
    }

    @MainActor
    func testFreshMissingSelectionStartsOrdinaryOnboarding() async {
        withDefaults { defaults in
            let store = AppStore(defaults: defaults)
            XCTAssertTrue(store.needsOnboarding)
            XCTAssertFalse(store.isRecoveringSelection)
            XCTAssertFalse(store.canClean(.keepFavourites))
            XCTAssertFalse(store.canClean(.closeAll))
            XCTAssertNil(defaults.object(forKey: selectionKey))
        }
    }

    @MainActor
    func testValidEmptyCompletedSelectionDoesNotRequestRecovery() async throws {
        try withDefaults { defaults in
            try ProtectedApplicationSettings(defaults: defaults).save([])
            defaults.set(true, forKey: onboardingKey)
            let store = AppStore(defaults: defaults)
            XCTAssertFalse(store.needsOnboarding)
            XCTAssertFalse(store.isRecoveringSelection)
            XCTAssertTrue(store.protectedApps.isEmpty)
        }
    }

    @MainActor
    func testFinishingRecoveryPersistsExplicitEmptyChoiceAndSurvivesRelaunch() async throws {
        try withDefaults { defaults in
            defaults.set(Data("broken selection".utf8), forKey: selectionKey)
            defaults.set(true, forKey: onboardingKey)
            let store = AppStore(defaults: defaults)
            XCTAssertTrue(store.isRecoveringSelection)

            store.finishOnboarding()
            XCTAssertFalse(store.isRecoveringSelection)
            XCTAssertFalse(store.needsOnboarding)
            XCTAssertTrue(defaults.bool(forKey: onboardingKey))
            let data = try XCTUnwrap(defaults.data(forKey: selectionKey))
            XCTAssertTrue(try JSONDecoder().decode([SavedApplication].self, from: data).isEmpty)

            let relaunched = AppStore(defaults: defaults)
            XCTAssertFalse(relaunched.isRecoveringSelection)
            XCTAssertFalse(relaunched.needsOnboarding)
            XCTAssertTrue(relaunched.protectedApps.isEmpty)
        }
    }

    @MainActor
    func testRecoverySelectionRemainsADraftUntilExplicitFinish() async throws {
        try withDefaults { defaults in
            let original = Data("broken selection".utf8)
            defaults.set(original, forKey: selectionKey)
            defaults.set(true, forKey: onboardingKey)
            let store = AppStore(defaults: defaults)
            let finder = SavedApplication(
                id: "bundle:com.apple.finder", name: "Finder",
                bundleIdentifier: "com.apple.finder", path: "/System/Library/CoreServices/Finder.app"
            )

            store.toggleOnboardingApplication(finder)
            XCTAssertEqual(store.onboardingApps.map(\.id), [finder.id])
            XCTAssertTrue(store.protectedApps.isEmpty)
            XCTAssertFalse(store.canClean(.keepFavourites))
            XCTAssertFalse(store.canClean(.closeAll))
            XCTAssertEqual(defaults.data(forKey: selectionKey), original)

            store.finishOnboarding()
            XCTAssertFalse(store.isRecoveringSelection)
            XCTAssertFalse(store.needsOnboarding)
            XCTAssertEqual(store.protectedApps.map(\.id), [finder.id])
            let saved = try JSONDecoder().decode([SavedApplication].self, from: XCTUnwrap(defaults.data(forKey: selectionKey)))
            XCTAssertEqual(saved.map(\.id), [finder.id])
            XCTAssertEqual(AppStore(defaults: defaults).protectedApps.map(\.id), [finder.id])
        }
    }

    @MainActor
    func testAbandonedRecoveryKeepsOriginalDataAndRequiresRecoveryAgain() async {
        withDefaults { defaults in
            let original = Data("broken selection".utf8)
            defaults.set(original, forKey: selectionKey)
            defaults.set(true, forKey: onboardingKey)
            let store = AppStore(defaults: defaults)
            XCTAssertTrue(store.isRecoveringSelection)

            let relaunched = AppStore(defaults: defaults)
            XCTAssertTrue(relaunched.isRecoveringSelection)
            XCTAssertTrue(relaunched.needsOnboarding)
            XCTAssertTrue(relaunched.onboardingApps.isEmpty)
            XCTAssertFalse(relaunched.canClean(.keepFavourites))
            XCTAssertFalse(relaunched.canClean(.closeAll))
            XCTAssertEqual(defaults.data(forKey: selectionKey), original)
        }
    }
}
