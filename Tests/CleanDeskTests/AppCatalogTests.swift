import Foundation
import XCTest
@testable import CleanDesk

final class AppCatalogTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanDeskCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @discardableResult
    private func makeApp(at url: URL, identifier: String, name: String, packageType: String = "APPL", backgroundOnly: Any? = nil) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/Fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": packageType
        ]
        if let backgroundOnly { info["LSBackgroundOnly"] = backgroundOnly }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return url
    }

    func testFinderOutsideApplicationRootsIsIncludedWithoutScanningItsNeighbors() throws {
        try withDirectory { root in
            let applications = root.appendingPathComponent("Applications")
            try makeApp(at: applications.appendingPathComponent("Editor.app"), identifier: "test.editor", name: "Editor")
            let finder = try makeApp(at: root.appendingPathComponent("CoreServices/Finder.app"), identifier: "com.apple.finder", name: "Finder", packageType: "FNDR")
            try makeApp(at: root.appendingPathComponent("CoreServices/System Utility.app"), identifier: "test.system-utility", name: "System Utility")

            let catalog = AppCatalog.discover(in: [applications], additionalApplications: [finder])
            XCTAssertEqual(catalog.map(\.name), ["Editor", "Finder"])
            XCTAssertEqual(catalog.first { $0.id == "bundle:com.apple.finder" }?.path, finder.resolvingSymlinksInPath().path)
        }
    }

    func testAdditionalFinderDoesNotDuplicateAnAlreadyDiscoveredBundle() throws {
        try withDirectory { root in
            let applications = root.appendingPathComponent("Applications")
            let firstFinder = try makeApp(at: applications.appendingPathComponent("Finder.app"), identifier: "com.apple.Finder", name: "Finder", packageType: "FNDR")
            let additionalFinder = try makeApp(at: root.appendingPathComponent("CoreServices/Finder.app"), identifier: "com.apple.finder", name: "Finder", packageType: "FNDR")

            let catalog = AppCatalog.discover(in: [applications], additionalApplications: [additionalFinder, additionalFinder])
            XCTAssertEqual(catalog.map(\.id), ["bundle:com.apple.finder"])
            XCTAssertEqual(catalog.first?.path, firstFinder.resolvingSymlinksInPath().path)
        }
    }

    func testCleanDeskAndBackgroundAppsRemainExcludedWhenFinderIsAllowed() throws {
        try withDirectory { root in
            let finder = try makeApp(at: root.appendingPathComponent("Finder.app"), identifier: "com.apple.finder", name: "Finder", packageType: "FNDR")
            let ownApp = try makeApp(at: root.appendingPathComponent("Clean Desk.app"), identifier: "pl.local.cleandesk", name: "Clean Desk")
            let helper = try makeApp(at: root.appendingPathComponent("Helper.app"), identifier: "test.helper", name: "Helper", backgroundOnly: true)
            let stringHelper = try makeApp(at: root.appendingPathComponent("Other Helper.app"), identifier: "test.other-helper", name: "Other Helper", backgroundOnly: "YES")

            let catalog = AppCatalog.discover(in: [root], additionalApplications: [finder, ownApp, helper, stringHelper])
            XCTAssertEqual(catalog.map(\.id), ["bundle:com.apple.finder"])
        }
    }

    func testMissingFinderIsNotInventedAndCustomRootsStayIsolated() throws {
        try withDirectory { root in
            XCTAssertTrue(AppCatalog.discover(in: [root]).isEmpty)
            XCTAssertTrue(AppCatalog.discover(in: [root], additionalApplications: [root.appendingPathComponent("Missing/Finder.app")]).isEmpty)

            let invalidFinder = try makeApp(at: root.appendingPathComponent("Finder.app"), identifier: "com.apple.finder", name: "Finder", packageType: "FNDR")
            try FileManager.default.removeItem(at: invalidFinder.appendingPathComponent("Contents/MacOS/Fixture"))
            XCTAssertTrue(AppCatalog.discover(in: [], additionalApplications: [invalidFinder]).isEmpty)
        }
    }

    func testFinderPackageTypeIsRejectedForOtherBundleIdentifiers() throws {
        try withDirectory { root in
            let otherApp = try makeApp(at: root.appendingPathComponent("Finder.app"), identifier: "test.other-app", name: "Finder", packageType: "FNDR")

            XCTAssertTrue(AppCatalog.discover(in: [root], additionalApplications: [otherApp]).isEmpty)
        }
    }
}
