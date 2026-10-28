import AppKit

struct ManagedApplication: Identifiable {
    let id: String
    let name: String
    let icon: NSImage
    let bundleIdentifier: String?
    let url: URL?
}

struct SavedApplication: Identifiable, Codable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let path: String?

    @MainActor var icon: NSImage {
        ApplicationIconCache.shared.icon(for: self)
    }

}

struct CleanupReport {
    let title: String
    let detail: String
    let remaining: [ManagedApplication]
    let isSuccess: Bool
    var launchFailures: [String] = []
    var hideFailures: [String] = []
    var showFailures: [String] = []
    var desktopFailures: [String] = []
    var desktopAccessDenied = false

    var message: String {
        var messages: [String] = []
        if desktopAccessDenied {
            messages.append("macOS denied access to Desktop or Trash.")
        } else if !desktopFailures.isEmpty {
            messages.append("Could not clean Desktop.")
        }
        if !launchFailures.isEmpty { messages.append("Could not open: " + launchFailures.joined(separator: ", ")) }
        if !remaining.isEmpty { messages.append("Could not close: " + remaining.map(\.name).joined(separator: ", ")) }
        if !hideFailures.isEmpty { messages.append("Could not hide: " + hideFailures.joined(separator: ", ")) }
        if !showFailures.isEmpty { messages.append("Could not show: " + showFailures.joined(separator: ", ")) }
        return messages.joined(separator: "\n")
    }
}

struct ReportSignature: Equatable {
    let title: String
    let detail: String
    let remaining: [String]
    let launchFailures: [String]
    let hideFailures: [String]
    let showFailures: [String]
    let desktopFailures: [String]
    let desktopAccessDenied: Bool

    init(_ report: CleanupReport) {
        title = report.title
        detail = report.detail
        remaining = report.remaining.map { $0.id + ":" + $0.name }
        launchFailures = report.launchFailures
        hideFailures = report.hideFailures
        showFailures = report.showFailures
        desktopFailures = report.desktopFailures
        desktopAccessDenied = report.desktopAccessDenied
    }
}
