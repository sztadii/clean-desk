import AppKit
import Foundation

/// A lease is retained by the filesystem task, including after its UI task is
/// cancelled. Overlapping operations share a lease and therefore one scope.
final class DesktopAccessLease: @unchecked Sendable {
    let url: URL?
    private let started: Bool

    init(url: URL?) {
        self.url = url
        started = url?.startAccessingSecurityScopedResource() ?? false
    }

    deinit {
        if started { url?.stopAccessingSecurityScopedResource() }
    }
}

@MainActor
protocol DesktopAccessProviding: AnyObject {
    var hasGrant: Bool { get }
    func acquire() -> DesktopAccessLease
    func requestGrant() async throws -> Bool
}

@MainActor
final class DesktopAccess: NSObject, NSOpenSavePanelDelegate, DesktopAccessProviding {
    private let defaults: UserDefaults
    private let bookmarkKey = "desktopAccessBookmark.v1"
    private var grantedURL: URL?
    private weak var activeLease: DesktopAccessLease?
    private var panel: NSOpenPanel?

    var hasGrant: Bool { grantedURL != nil }

    private var systemDesktop: URL? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        restoreBookmark()
    }

    func acquire() -> DesktopAccessLease {
        let url = grantedURL ?? systemDesktop
        if let lease = activeLease, lease.url == url { return lease }
        let lease = DesktopAccessLease(url: url)
        activeLease = lease
        return lease
    }

    /// Called only after explicit first-enable or recovery intent, never from a scan.
    func requestGrant() async throws -> Bool {
        guard let desktop = systemDesktop else { throw accessError("The Desktop folder could not be found.") }
        guard panel == nil else { return false }
        let picker = NSOpenPanel()
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.canCreateDirectories = false
        picker.allowsMultipleSelection = false
        picker.directoryURL = desktop
        picker.prompt = "Grant access"
        picker.message = "Select Desktop to allow Clean Desk to move its visible files to Trash."
        picker.delegate = self
        panel = picker
        NSApp.activate(ignoringOtherApps: true)
        return try await withCheckedThrowingContinuation { continuation in
            picker.begin { [weak self] response in
                Task { @MainActor [weak self] in
                    guard let self else { continuation.resume(returning: false); return }
                    defer { self.panel = nil }
                    guard response == .OK, let selected = picker.url else {
                        continuation.resume(returning: false)
                        return
                    }
                    do {
                        try self.validateDesktop(selected)
                        let lease = DesktopAccessLease(url: selected)
                        let data = try withExtendedLifetime(lease) {
                            try selected.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                        }
                        self.defaults.set(data, forKey: self.bookmarkKey)
                        self.grantedURL = selected
                        self.activeLease = lease
                        continuation.resume(returning: true)
                    } catch {
                        continuation.resume(throwing: self.accessError("Could not save Desktop access. Please try again."))
                    }
                }
            }
        }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        try validateDesktop(url)
    }

    private func validateDesktop(_ url: URL) throws {
        guard let desktop = systemDesktop,
              url.isFileURL,
              !url.pathComponents.contains(where: { $0 == "." || $0 == ".." }),
              url.standardizedFileURL.path == desktop.standardizedFileURL.path else {
            throw accessError("Select the Desktop folder, not a parent folder or a different location.")
        }
        // The cleaner independently checks actual directory/file identity and
        // rejects symlinks before every move. Do not resolve aliases here.
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey])
        guard values.isDirectory == true, values.isSymbolicLink == false, values.isAliasFile != true else {
            throw accessError("Select the Desktop folder itself, not an alias or symbolic link.")
        }
    }

    private func restoreBookmark() {
        guard let data = defaults.data(forKey: bookmarkKey) else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale)
            let lease = DesktopAccessLease(url: url)
            try withExtendedLifetime(lease) {
                try validateDesktop(url)
                if stale {
                    let refreshed = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                    defaults.set(refreshed, forKey: bookmarkKey)
                }
            }
            grantedURL = url
        } catch {
            // An obsolete bookmark cannot silently broaden the selected location.
            // Recovery remains an explicit action after an actual access failure.
            grantedURL = nil
        }
    }

    private func accessError(_ message: String) -> NSError {
        NSError(domain: "CleanDesk.DesktopAccess", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
