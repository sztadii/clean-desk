import CleanDeskCore

/// Keep the security-scoped lease alive for the entire filesystem operation,
/// including when its awaiting UI task is cancelled.
@MainActor
final class DesktopFileService {
    private let access: any DesktopAccessProviding

    init(access: any DesktopAccessProviding) { self.access = access }

    func inspect() async -> DesktopInspectionResult {
        guard access.hasGrant else {
            return DesktopInspectionResult(eligibleCount: 0, failures: ["Grant Desktop access to check files."], accessDenied: true)
        }
        let lease = access.acquire()
        return await Task.detached(priority: .utility) {
            withExtendedLifetime(lease) { DesktopCleaner.inspect(directory: lease.url) }
        }.value
    }

    func clean() async -> DesktopCleanupResult {
        guard access.hasGrant else {
            return DesktopCleanupResult(trashedCount: 0, failures: ["Grant Desktop access to move files to Trash."], accessDenied: true)
        }
        let lease = access.acquire()
        return await Task.detached(priority: .userInitiated) {
            withExtendedLifetime(lease) { DesktopCleaner.clean(directory: lease.url) }
        }.value
    }
}
