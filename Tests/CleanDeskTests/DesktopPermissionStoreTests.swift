import Combine
import XCTest
@testable import CleanDesk

final class DesktopPermissionStoreTests: XCTestCase {
    private let enabledKey = "cleanDesktopEnabled.v1"

    @MainActor
    private func withDefaults(
        enabled: Bool,
        _ body: (UserDefaults) async throws -> Void
    ) async throws {
        let suite = "CleanDeskTests.DesktopPermission.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(enabled, forKey: enabledKey)
        defaults.set(true, forKey: "onboardingCompleted.v1")
        try ProtectedApplicationSettings(defaults: defaults).save([])
        try await body(defaults)
    }

    @MainActor
    private func completePermissionRequest(_ store: AppStore, action: () -> Void) async {
        let completed = expectation(description: "Permission request completed")
        let observation = store.$isGrantingDesktopAccess
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in completed.fulfill() }
        defer { observation.cancel() }
        action()
        XCTAssertTrue(store.isGrantingDesktopAccess)
        XCTAssertFalse(store.canClean(.keepFavourites))
        XCTAssertFalse(store.canClean(.closeAll))
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertFalse(store.isGrantingDesktopAccess)
    }

    @MainActor
    func testCancelledGrantRecoveryPreservesEnabledPreference() async throws {
        try await withDefaults(enabled: true) { defaults in
            let access = FakeDesktopAccess(result: .success(false))
            let store = AppStore(defaults: defaults, desktopAccess: access)
            XCTAssertTrue(store.cleanDesktopEnabled)
            XCTAssertTrue(store.desktopNeedsAccess)
            XCTAssertTrue(defaults.bool(forKey: enabledKey))

            await completePermissionRequest(store) {
                store.grantDesktopAccess()
                XCTAssertTrue(defaults.bool(forKey: enabledKey))
            }

            XCTAssertEqual(access.requestCount, 1)
            XCTAssertEqual(access.acquireCount, 0)
            XCTAssertTrue(store.cleanDesktopEnabled)
            XCTAssertTrue(store.desktopNeedsAccess)
            XCTAssertTrue(defaults.bool(forKey: enabledKey))
        }
    }

    @MainActor
    func testCancelledFirstEnableStaysDisabled() async throws {
        try await withDefaults(enabled: false) { defaults in
            let access = FakeDesktopAccess(result: .success(false))
            let store = AppStore(defaults: defaults, desktopAccess: access)

            await completePermissionRequest(store) {
                store.setCleanDesktopEnabled(true)
                XCTAssertFalse(defaults.bool(forKey: enabledKey))
            }

            XCTAssertEqual(access.requestCount, 1)
            XCTAssertEqual(access.acquireCount, 0)
            XCTAssertFalse(store.cleanDesktopEnabled)
            XCTAssertFalse(defaults.bool(forKey: enabledKey))
            XCTAssertNil(store.report)
        }
    }

    @MainActor
    func testFailedGrantRecoveryPreservesEnabledPreference() async throws {
        try await withDefaults(enabled: true) { defaults in
            let access = FakeDesktopAccess(result: .failure(FakeDesktopAccess.Failure.unavailable))
            let store = AppStore(defaults: defaults, desktopAccess: access)

            await completePermissionRequest(store) {
                store.grantDesktopAccess()
            }

            XCTAssertEqual(access.requestCount, 1)
            XCTAssertEqual(access.acquireCount, 0)
            XCTAssertTrue(store.cleanDesktopEnabled)
            XCTAssertTrue(defaults.bool(forKey: enabledKey))
            XCTAssertTrue(store.desktopNeedsAccess)
            XCTAssertNotNil(store.report)
        }
    }

    @MainActor
    func testSuccessfulGrantEnablesAndPersistsDesktopCleanup() async throws {
        try await withDefaults(enabled: false) { defaults in
            let access = FakeDesktopAccess(result: .success(true))
            let store = AppStore(defaults: defaults, desktopAccess: access)

            await completePermissionRequest(store) {
                store.setCleanDesktopEnabled(true)
            }

            XCTAssertEqual(access.requestCount, 1)
            XCTAssertTrue(access.hasGrant)
            XCTAssertTrue(store.cleanDesktopEnabled)
            XCTAssertTrue(defaults.bool(forKey: enabledKey))
            // Finish any automatic inspection before releasing this fixture.
            await store.refreshDesktopStatus()
            XCTAssertGreaterThan(access.acquireCount, 0)
        }
    }
}

@MainActor
private final class FakeDesktopAccess: DesktopAccessProviding {
    enum Failure: Error { case unavailable }

    private let result: Result<Bool, Error>
    private(set) var hasGrant = false
    private(set) var requestCount = 0
    private(set) var acquireCount = 0

    init(result: Result<Bool, Error>) {
        self.result = result
    }

    func requestGrant() async throws -> Bool {
        requestCount += 1
        let granted = try result.get()
        hasGrant = granted
        return granted
    }

    func acquire() -> DesktopAccessLease {
        acquireCount += 1
        // A non-file URL is rejected before DesktopCleaner touches the filesystem.
        // This fixture must never fall back to the user's actual Desktop.
        return DesktopAccessLease(url: URL(string: "cleandesk-test://desktop")!)
    }
}
