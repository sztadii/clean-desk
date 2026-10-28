import CoreGraphics
import XCTest
@testable import CleanDesk

final class FinderWindowsTests: XCTestCase {
    private func window(pid: Int32 = 123, layer: Int = 0, onScreen: Bool = true,
                        alpha: Double = 1, width: Double = 800, height: Double = 600) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowIsOnscreen as String: onScreen,
            kCGWindowAlpha as String: alpha,
            kCGWindowBounds as String: ["Width": width, "Height": height]
        ]
    }

    func testNormalFinderWindowIsDetectedWithoutTitleOrScreenRecordingMetadata() {
        XCTAssertTrue(FinderWindows.hasVisibleWindow(processIdentifier: 123, in: [window()]))
    }

    func testDesktopElementsAndOtherApplicationsDoNotEnableFinderCleanup() {
        let desktop = window(layer: Int(CGWindowLevelForKey(.desktopWindow)))
        let icons = window(layer: Int(CGWindowLevelForKey(.desktopIconWindow)))
        XCTAssertFalse(FinderWindows.hasVisibleWindow(processIdentifier: 123, in: [desktop, icons, window(pid: 456)]))
    }

    func testOffscreenInvisibleAndEmptyWindowsAreIgnored() {
        let windows = [window(onScreen: false), window(alpha: 0), window(width: 0), window(height: 0)]
        XCTAssertFalse(FinderWindows.hasVisibleWindow(processIdentifier: 123, in: windows))
    }

    func testUnavailableOrIncompleteMetadataDoesNotInventAVisibleWindow() {
        XCTAssertFalse(FinderWindows.hasVisibleWindow(processIdentifier: 123, in: nil))
        XCTAssertFalse(FinderWindows.hasVisibleWindow(processIdentifier: 123, in: []))
        for key in [kCGWindowOwnerPID, kCGWindowLayer, kCGWindowIsOnscreen, kCGWindowAlpha, kCGWindowBounds] {
            var metadata = window()
            metadata.removeValue(forKey: key as String)
            XCTAssertFalse(FinderWindows.hasVisibleWindow(processIdentifier: 123, in: [metadata]))
        }
    }
}
