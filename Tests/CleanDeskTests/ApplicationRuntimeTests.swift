import AppKit
import XCTest
@testable import CleanDesk

@MainActor
final class ApplicationRuntimeTests: XCTestCase {
    func testSelectedInstallationWinsOverLaunchServicesAndFallsBackWhenRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("Selected.app")
        let registered = root.appendingPathComponent("Registered.app")
        for url in [selected, registered] {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "test.launch.selection", "CFBundlePackageType": "APPL"
            ], format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let runtime = ApplicationRuntime(workspace: .shared, applicationURL: { _ in registered })
        let app = SavedApplication(id: "bundle:test.launch.selection", name: "Selected", bundleIdentifier: "test.launch.selection", path: selected.path)
        XCTAssertEqual(runtime.resolve(app)?.path, selected.path)
        try FileManager.default.removeItem(at: selected)
        XCTAssertEqual(runtime.resolve(app)?.path, registered.path)
    }

    func testSavedPathBelongingToAnotherApplicationIsNeverLaunched() {
        let runtime = ApplicationRuntime(workspace: .shared, applicationURL: { _ in nil })
        let app = SavedApplication(id: "bundle:test.unrelated", name: "Missing", bundleIdentifier: "test.unrelated", path: "/System/Applications/Utilities/Terminal.app")
        XCTAssertNil(runtime.resolve(app))
    }
}
