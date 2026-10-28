import XCTest
@testable import CleanDesk

final class DesktopFileServiceTests: XCTestCase {
    @MainActor
    func testMissingGrantReturnsRecoverableFailureWithoutInspectingOrMovingFiles() async throws {
        let suite = "CleanDeskTests.DesktopFiles.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = DesktopFileService(access: DesktopAccess(defaults: defaults))

        let inspection = await service.inspect()
        let result = await service.clean()

        XCTAssertEqual(inspection.eligibleCount, 0)
        XCTAssertTrue(inspection.accessDenied)
        XCTAssertFalse(inspection.failures.isEmpty)
        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertTrue(result.accessDenied)
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertNil(defaults.data(forKey: "desktopAccessBookmark.v1"))
    }

    @MainActor
    func testLostGrantPreservesDesktopPreferenceAndOffersRecovery() async throws {
        let suite = "CleanDeskTests.DesktopPreference.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "cleanDesktopEnabled.v1")
        let store = AppStore(defaults: defaults)

        XCTAssertTrue(store.cleanDesktopEnabled)
        XCTAssertTrue(store.desktopNeedsAccess)
        XCTAssertTrue(defaults.bool(forKey: "cleanDesktopEnabled.v1"))
        XCTAssertNil(store.desktopFileCount)
        XCTAssertNil(store.report)
    }
}
