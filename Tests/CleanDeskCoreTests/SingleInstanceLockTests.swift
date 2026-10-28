import Darwin
import Foundation
import XCTest
@testable import CleanDeskCore

final class SingleInstanceLockTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CleanDeskLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    func testSecondAcquisitionOfTheSamePathIsBusy() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("nested/instance.lock")
            let first = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
            try withExtendedLifetime(first) {
                XCTAssertNil(try SingleInstanceLock.acquire(at: url))
            }
        }
    }

    func testReleasingTheLeaseAllowsAnotherInstanceWithoutDeletingTheFile() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("instance.lock")
            var first: SingleInstanceLock? = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
            try withExtendedLifetime(first) {
                XCTAssertNil(try SingleInstanceLock.acquire(at: url))
            }
            first = nil
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let second = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
            try withExtendedLifetime(second) {
                XCTAssertNil(try SingleInstanceLock.acquire(at: url))
            }
        }
    }

    func testDifferentPathsCanBeHeldIndependently() throws {
        try withDirectory { directory in
            let firstURL = directory.appendingPathComponent("first.lock")
            let secondURL = directory.appendingPathComponent("second.lock")
            let first = try XCTUnwrap(SingleInstanceLock.acquire(at: firstURL))
            let second = try XCTUnwrap(SingleInstanceLock.acquire(at: secondURL))
            try withExtendedLifetime((first, second)) {
                XCTAssertNil(try SingleInstanceLock.acquire(at: firstURL))
                XCTAssertNil(try SingleInstanceLock.acquire(at: secondURL))
            }
        }
    }

    func testStaleFileDoesNotPreventAcquisition() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("instance.lock")
            try Data().write(to: url)
            let lease = try XCTUnwrap(SingleInstanceLock.acquire(at: url))
            withExtendedLifetime(lease) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    func testOpenFailureThrowsInsteadOfReportingAnotherRunningInstance() throws {
        try withDirectory { directory in
            XCTAssertThrowsError(try SingleInstanceLock.acquire(at: directory)) { error in
                let error = error as NSError
                XCTAssertEqual(error.domain, NSPOSIXErrorDomain)
                XCTAssertEqual(error.code, Int(EISDIR))
            }
        }
    }

    func testSymbolicLinkIsNotFollowed() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("target")
            let url = directory.appendingPathComponent("instance.lock")
            let contents = Data("Keep this file unchanged".utf8)
            try contents.write(to: target)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            XCTAssertThrowsError(try SingleInstanceLock.acquire(at: url)) { error in
                XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            }
            XCTAssertEqual(try Data(contentsOf: target), contents)
        }
    }
}
