import Combine
import ServiceManagement

@MainActor
protocol LaunchAtLoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
private struct SystemLaunchAtLoginService: LaunchAtLoginService {
    var status: SMAppService.Status { SMAppService.mainApp.status }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LaunchAtLoginSettings: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    private let service: any LaunchAtLoginService

    // A pending registration remains checked so it can also be turned off.
    // The UI explains separately when macOS still requires approval.
    var enabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    init(service: (any LaunchAtLoginService)? = nil) {
        let service = service ?? SystemLaunchAtLoginService()
        self.service = service
        self.status = service.status
    }

    func refresh() {
        let updatedStatus = service.status
        if updatedStatus != status { errorMessage = nil }
        status = updatedStatus
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        guard enabled != self.enabled else { return }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            refresh()
        } catch {
            // Registration can be retained even when approval is denied. Always
            // reflect the actual system status instead of an optimistic value.
            refresh()
            if enabled && requiresApproval { return }
            errorMessage = enabled
                ? "Could not enable launch at login. Try again or check Login Items in System Settings."
                : "Could not disable launch at login. Try again or check Login Items in System Settings."
        }
    }

    func openSystemSettings() {
        service.openSystemSettings()
    }
}
