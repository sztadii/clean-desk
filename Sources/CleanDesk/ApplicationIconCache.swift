import AppKit

/// Cache both saved-app lookups and file icons across view updates. App lifecycle
/// notifications invalidate it, so an updated or relocated app gets a fresh icon.
@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()
    private let images = NSCache<NSString, NSImage>()
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
        images.countLimit = 256
    }

    func icon(for app: SavedApplication) -> NSImage {
        let key = "saved:\(app.id):\(app.path ?? "")" as NSString
        if let image = images.object(forKey: key) { return image }
        let url = app.bundleIdentifier.flatMap { workspace.urlForApplication(withBundleIdentifier: $0) }
        let image = icon(at: url?.path ?? app.path)
        images.setObject(image, forKey: key)
        return image
    }

    func icon(at path: String?, fallback: () -> NSImage? = { nil }) -> NSImage {
        let key = (path ?? "generic") as NSString
        if let image = images.object(forKey: key) { return image }
        let image = fallback() ?? path.map { workspace.icon(forFile: $0) }
            ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 32, height: 32))
        images.setObject(image, forKey: key)
        return image
    }

    func invalidate() { images.removeAllObjects() }
}
