import ServiceManagement
import XCTest
@testable import CleanDesk

final class LaunchAtLoginSettingsTests: XCTestCase {
    @MainActor
    func testReadingSettingsDoesNotRegisterOrUnregisterTheApp() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let settings = LaunchAtLoginSettings(service: service)

        XCTAssertTrue(settings.enabled)
        settings.refresh()
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
    }

    @MainActor
    func testToggleRegistersAndUnregistersTheApp() {
        let service = FakeLaunchAtLoginService()
        let settings = LaunchAtLoginSettings(service: service)

        settings.setEnabled(true)
        XCTAssertTrue(settings.enabled)
        XCTAssertFalse(settings.requiresApproval)
        XCTAssertEqual(service.registerCount, 1)
        settings.setEnabled(true)
        XCTAssertEqual(service.registerCount, 1)

        settings.setEnabled(false)
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(service.unregisterCount, 1)
        settings.setEnabled(false)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    @MainActor
    func testPendingApprovalStaysCheckedAndCanBeCancelled() {
        let service = FakeLaunchAtLoginService()
        service.registrationStatus = .requiresApproval
        let settings = LaunchAtLoginSettings(service: service)

        settings.setEnabled(true)
        XCTAssertTrue(settings.enabled)
        XCTAssertTrue(settings.requiresApproval)
        XCTAssertNil(settings.errorMessage)
        settings.setEnabled(true)
        XCTAssertEqual(service.registerCount, 1)

        settings.openSystemSettings()
        XCTAssertEqual(service.openSystemSettingsCount, 1)
        settings.setEnabled(false)
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.requiresApproval)
        XCTAssertEqual(service.unregisterCount, 1)
    }

    @MainActor
    func testRefreshReflectsChangesMadeInSystemSettings() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        let settings = LaunchAtLoginSettings(service: service)

        service.status = .requiresApproval
        settings.refresh()
        XCTAssertTrue(settings.requiresApproval)

        service.status = .notRegistered
        settings.refresh()
        XCTAssertFalse(settings.enabled)
        XCTAssertFalse(settings.requiresApproval)
        XCTAssertEqual(service.registerCount, 0)
        XCTAssertEqual(service.unregisterCount, 0)
    }

    @MainActor
    func testFailedRegistrationKeepsActualStatusAndRetryClearsError() {
        let service = FakeLaunchAtLoginService()
        service.registrationError = FakeLaunchAtLoginService.Failure.unavailable
        let settings = LaunchAtLoginSettings(service: service)

        settings.setEnabled(true)
        XCTAssertFalse(settings.enabled)
        XCTAssertNotNil(settings.errorMessage)

        service.registrationError = nil
        settings.setEnabled(true)
        XCTAssertTrue(settings.enabled)
        XCTAssertNil(settings.errorMessage)
    }

    @MainActor
    func testDeniedRegistrationThatNeedsApprovalShowsApprovalState() {
        let service = FakeLaunchAtLoginService()
        service.registrationStatus = .requiresApproval
        service.registrationError = FakeLaunchAtLoginService.Failure.unavailable
        service.changesStatusBeforeRegistrationError = true
        let settings = LaunchAtLoginSettings(service: service)

        settings.setEnabled(true)
        XCTAssertTrue(settings.enabled)
        XCTAssertTrue(settings.requiresApproval)
        XCTAssertNil(settings.errorMessage)
    }

    @MainActor
    func testFailedUnregistrationDoesNotPretendLaunchAtLoginIsOff() {
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.unregistrationError = FakeLaunchAtLoginService.Failure.unavailable
        let settings = LaunchAtLoginSettings(service: service)

        settings.setEnabled(false)
        XCTAssertTrue(settings.enabled)
        XCTAssertNotNil(settings.errorMessage)

        service.status = .notRegistered
        settings.refresh()
        XCTAssertFalse(settings.enabled)
        XCTAssertNil(settings.errorMessage)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginService {
    enum Failure: Error { case unavailable }

    var status: SMAppService.Status
    var registrationStatus: SMAppService.Status = .enabled
    var registrationError: Error?
    var unregistrationError: Error?
    var changesStatusBeforeRegistrationError = false
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openSystemSettingsCount = 0

    init(status: SMAppService.Status = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registerCount += 1
        if changesStatusBeforeRegistrationError { status = registrationStatus }
        if let registrationError { throw registrationError }
        status = registrationStatus
    }

    func unregister() throws {
        unregisterCount += 1
        if let unregistrationError { throw unregistrationError }
        status = .notRegistered
    }

    func openSystemSettings() {
        openSystemSettingsCount += 1
    }
}
