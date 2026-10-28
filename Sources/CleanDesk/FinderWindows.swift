import CoreGraphics
import Foundation

enum FinderWindows {
    static func hasVisibleWindow(processIdentifier: Int32) -> Bool {
        // Read only window metadata; no titles, screenshots, or accessibility
        // access. Excluding desktop elements keeps Finder's desktop icons out.
        let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]]
        return hasVisibleWindow(processIdentifier: processIdentifier, in: windows)
    }

    static func hasVisibleWindow(processIdentifier: Int32, in windows: [[String: Any]]?) -> Bool {
        guard let windows else { return false }
        return windows.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? NSNumber, width.doubleValue > 0,
                  let height = bounds["Height"] as? NSNumber, height.doubleValue > 0 else { return false }
            return true
        }
    }
}
