import Darwin
import Foundation
import XCTest
@testable import CleanDeskCore

final class DesktopCleanerTests: XCTestCase {
    private var fixtureRoot: URL!
    private var desktop: URL!
    private let fileManager = FileManager.default

    override func setUpWithError() throws {
        fixtureRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("CleanDesk-DesktopTests-\(UUID().uuidString)", isDirectory: true)
        desktop = fixtureRoot.appendingPathComponent("Desktop", isDirectory: true)
        try fileManager.createDirectory(at: desktop, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Only our isolated fixtures are deleted. No test calls the real Trash API.
        if let fixtureRoot { try fileManager.removeItem(at: fixtureRoot) }
    }

    @discardableResult
    private func file(_ name: String, in directory: URL? = nil) throws -> URL {
        let url = (directory ?? desktop).appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }

    private func hide(_ url: URL) throws {
        var mutableURL = url
        var values = URLResourceValues()
        values.isHidden = true
        try mutableURL.setResourceValues(values)
    }

    func testInspectionOfEmptyDesktopReturnsZeroWithoutChanges() throws {
        let result = DesktopCleaner.inspect(directory: desktop)

        XCTAssertEqual(result.eligibleCount, 0)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: desktop.path).isEmpty)
    }

    func testInspectionOfOnlyExcludedItemsReturnsZeroAndPreservesEverything() throws {
        let dotfile = try file(".keep")
        let hidden = try file("Finder-hidden.txt")
        try hide(hidden)
        let folder = desktop.appendingPathComponent("Folder", isDirectory: true)
        let package = desktop.appendingPathComponent("Sample.app", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: package, withIntermediateDirectories: false)
        let nested = try file("nested.txt", in: folder)
        let packageContents = try file("Contents.txt", in: package)
        let outside = try file("outside.txt", in: fixtureRoot)
        let link = desktop.appendingPathComponent("linked.txt")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)
        let alias = desktop.appendingPathComponent("Finder alias")
        let bookmark = try outside.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        let originalNames = try fileManager.contentsOfDirectory(atPath: desktop.path).sorted()
        let preservedFiles = [dotfile, hidden, nested, packageContents, outside, alias]
        let originalContents = try preservedFiles.map { try Data(contentsOf: $0) }

        let result = DesktopCleaner.inspect(directory: desktop)

        XCTAssertEqual(result.eligibleCount, 0)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: desktop.path).sorted(), originalNames)
        XCTAssertEqual(try preservedFiles.map { try Data(contentsOf: $0) }, originalContents)
        XCTAssertEqual(try hidden.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
        XCTAssertEqual(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile, true)
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: link.path), outside.path)
    }

    func testInspectionCountsTheSameVisibleFilesAsCleanupWithoutMutatingThem() throws {
        let screenshot = try file("Screenshot.png")
        let note = try file("notes.txt")
        let hidden = try file(".hidden")
        let originalNames = try fileManager.contentsOfDirectory(atPath: desktop.path).sorted()
        let originalContents = try [screenshot, note, hidden].map { try Data(contentsOf: $0) }

        let inspection = DesktopCleaner.inspect(directory: desktop)

        XCTAssertEqual(inspection.eligibleCount, 2)
        XCTAssertTrue(inspection.failures.isEmpty)
        XCTAssertEqual(try fileManager.contentsOfDirectory(atPath: desktop.path).sorted(), originalNames)
        XCTAssertEqual(try [screenshot, note, hidden].map { try Data(contentsOf: $0) }, originalContents)
        var attempted: [URL] = []
        let cleanup = DesktopCleaner.clean(directory: desktop, trash: { attempted.append($0) })
        XCTAssertEqual(cleanup.trashedCount, inspection.eligibleCount)
        XCTAssertEqual(Set(attempted), [screenshot, note])
    }

    func testInspectionDenialIsAnExplicitFailureNotAnEmptyDesktop() throws {
        let preserved = try file("notes.txt")
        let denied = ListingFileManager { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }

        let result = DesktopCleaner.inspect(directory: desktop, fileManager: denied)

        XCTAssertEqual(result.eligibleCount, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.accessDenied)
        XCTAssertTrue(result.failures.first?.contains("macOS denied access") == true)
        XCTAssertEqual(try Data(contentsOf: preserved), Data("fixture".utf8))
    }

    func testInspectionRetainsFailuresAlongsidePartialCounts() throws {
        let visible = try file("notes.txt")
        let missing = desktop.appendingPathComponent("missing.txt")
        let listing = ListingFileManager { _ in [visible, missing] }

        let result = DesktopCleaner.inspect(directory: desktop, fileManager: listing)

        XCTAssertEqual(result.eligibleCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures.first?.contains("missing.txt") == true)
        XCTAssertEqual(try Data(contentsOf: visible), Data("fixture".utf8))
    }

    func testOnlyVisibleTopLevelRegularFilesAreSentToTrash() throws {
        let screenshot = try file("Screenshot.png")
        let note = try file("notes.txt")
        let dotfile = try file(".keep")
        let finderHidden = try file("hidden-by-Finder.txt")
        try hide(finderHidden)
        let folder = desktop.appendingPathComponent("Folder", isDirectory: true)
        let package = desktop.appendingPathComponent("Sample.app", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: package, withIntermediateDirectories: false)
        let nested = try file("nested.txt", in: folder)
        let packageContent = try file("Contents.txt", in: package)
        var trashed: [URL] = []

        let result = DesktopCleaner.clean(directory: desktop, trash: { trashed.append($0) })

        XCTAssertEqual(Set(trashed), [screenshot, note])
        XCTAssertEqual(result.trashedCount, 2)
        XCTAssertTrue(result.failures.isEmpty)
        for preserved in [dotfile, finderHidden, folder, package, nested, packageContent] {
            XCTAssertTrue(fileManager.fileExists(atPath: preserved.path))
        }
    }

    func testSymlinksAliasesAndSpecialFilesArePreserved() throws {
        let external = try file("outside.txt", in: fixtureRoot)
        let symlink = desktop.appendingPathComponent("linked.txt")
        let brokenLink = desktop.appendingPathComponent("broken.txt")
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: external)
        try fileManager.createSymbolicLink(at: brokenLink, withDestinationURL: fixtureRoot.appendingPathComponent("missing.txt"))
        let alias = desktop.appendingPathComponent("Finder alias")
        let bookmark = try external.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        XCTAssertEqual(try alias.resourceValues(forKeys: [.isAliasFileKey]).isAliasFile, true)
        let fifo = desktop.appendingPathComponent("pipe")
        XCTAssertEqual(fifo.withUnsafeFileSystemRepresentation { Darwin.mkfifo($0!, mode_t(0o600)) }, 0)
        var trashed: [URL] = []

        let result = DesktopCleaner.clean(directory: desktop, trash: { trashed.append($0) })

        XCTAssertTrue(trashed.isEmpty)
        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: external), Data("fixture".utf8))
        XCTAssertEqual(try fileManager.destinationOfSymbolicLink(atPath: symlink.path), external.path)
    }

    func testTrashFailureIsReportedAndOtherFilesCanContinue() throws {
        let first = try file("a.txt")
        let second = try file("b.txt")
        var trashed: [URL] = []

        let result = DesktopCleaner.clean(directory: desktop, trash: { url in
            if url == first { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
            trashed.append(url)
        })

        XCTAssertEqual(trashed, [second])
        XCTAssertEqual(result.trashedCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].contains("a.txt"))
        XCTAssertFalse(result.accessDenied)
    }

    func testListingDenialIsNotReportedAsEmptySuccess() {
        let denied = ListingFileManager { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        }
        var attemptedTrash = false
        let result = DesktopCleaner.clean(directory: desktop, fileManager: denied, trash: { _ in attemptedTrash = true })

        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertFalse(attemptedTrash)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.accessDenied)
    }

    func testMissingDesktopAndMissingEntryProduceExplicitFailures() {
        let missing = DesktopCleaner.clean(directory: desktop.appendingPathComponent("missing"), trash: { _ in XCTFail("Must not trash anything") })
        XCTAssertFalse(missing.failures.isEmpty)
        XCTAssertFalse(missing.accessDenied)

        let ghost = desktop.appendingPathComponent("ghost.txt")
        let listing = ListingFileManager { _ in [ghost] }
        let inaccessibleEntry = DesktopCleaner.clean(directory: desktop, fileManager: listing, trash: { _ in XCTFail("Must not trash anything") })
        XCTAssertEqual(inaccessibleEntry.trashedCount, 0)
        XCTAssertEqual(inaccessibleEntry.failures.count, 1)
        XCTAssertTrue(inaccessibleEntry.failures[0].contains("ghost.txt"))
    }

    func testItemsOutsideTheSelectedFolderAreRejected() throws {
        let outside = try file("outside.txt", in: fixtureRoot)
        let inside = try file("inside.txt")
        try fileManager.createDirectory(at: desktop.appendingPathComponent("nested", isDirectory: true), withIntermediateDirectories: false)
        let traversal = desktop.appendingPathComponent("nested/../inside.txt")
        XCTAssertTrue(traversal.pathComponents.contains(".."))
        let listing = ListingFileManager { _ in [outside, traversal] }
        let result = DesktopCleaner.clean(directory: desktop, fileManager: listing, trash: { _ in XCTFail("Outside item must never be trashed") })
        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertEqual(result.failures.count, 2)
        XCTAssertTrue(fileManager.fileExists(atPath: outside.path))
        XCTAssertTrue(fileManager.fileExists(atPath: inside.path))
    }

    func testTrashPermissionDenialOffersRecoveryAndPreservesTheFile() throws {
        let screenshot = try file("Screenshot.png")
        let result = DesktopCleaner.clean(directory: desktop, trash: { _ in
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        })

        XCTAssertTrue(result.accessDenied)
        XCTAssertEqual(result.trashedCount, 0)
        XCTAssertTrue(result.failures[0].contains("NSCocoaErrorDomain 513"))
        XCTAssertFalse(result.failures[0].contains("Files and Folders"))
        XCTAssertEqual(try Data(contentsOf: screenshot), Data("fixture".utf8))
    }

    func testUnderlyingPermissionDenialIsPreservedInPartialCleanup() throws {
        let first = try file("a.txt")
        let second = try file("b.txt")
        var accepted: [URL] = []
        let result = DesktopCleaner.clean(directory: desktop, trash: { url in
            if url == first {
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [
                    NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)),
                ])
            }
            accepted.append(url)
        })

        XCTAssertTrue(result.accessDenied)
        XCTAssertEqual(result.trashedCount, 1)
        XCTAssertEqual(accepted, [second])
        XCTAssertEqual(try Data(contentsOf: first), Data("fixture".utf8))
    }

    func testFilesHiddenAfterTheSnapshotAreRecheckedAndPreserved() throws {
        let first = try file("a.txt")
        let changed = try file("b.txt")
        var trashed: [URL] = []
        let result = DesktopCleaner.clean(directory: desktop, trash: { url in
            trashed.append(url)
            if url == first { try self.hide(changed) }
        })

        XCTAssertEqual(trashed, [first])
        XCTAssertEqual(result.trashedCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: changed.path))
    }

    func testReplacedFileIsNotMovedEvenIfReplacementIsRegular() throws {
        let first = try file("a.txt")
        let changed = try file("b.txt")
        var trashed: [URL] = []
        let result = DesktopCleaner.clean(directory: desktop, trash: { url in
            trashed.append(url)
            if url == first {
                try self.fileManager.moveItem(at: changed, to: self.fixtureRoot.appendingPathComponent("original-b.txt"))
                try Data("replacement".utf8).write(to: changed)
            }
        })

        XCTAssertEqual(trashed, [first])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: changed), Data("replacement".utf8))
    }

    func testReplacementSymlinkAndRootSymlinkAreNotFollowed() throws {
        let first = try file("a.txt")
        let changed = try file("b.txt")
        let outside = try file("outside.txt", in: fixtureRoot)
        var trashed: [URL] = []
        let result = DesktopCleaner.clean(directory: desktop, trash: { url in
            trashed.append(url)
            if url == first {
                try self.fileManager.moveItem(at: changed, to: self.fixtureRoot.appendingPathComponent("original-b.txt"))
                try self.fileManager.createSymbolicLink(at: changed, withDestinationURL: outside)
            }
        })

        XCTAssertEqual(trashed, [first])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: outside), Data("fixture".utf8))

        let rootLink = fixtureRoot.appendingPathComponent("Desktop-link")
        try fileManager.createSymbolicLink(at: rootLink, withDestinationURL: desktop)
        let linkedRootResult = DesktopCleaner.clean(directory: rootLink, trash: { _ in XCTFail("A root symlink must not be followed") })
        XCTAssertEqual(linkedRootResult.trashedCount, 0)
        XCTAssertFalse(linkedRootResult.failures.isEmpty)
    }

    func testReplacingTheRootStopsTheRemainingCleanup() throws {
        let first = try file("a.txt")
        try file("b.txt")
        let replacement = desktop.appendingPathComponent("b.txt")
        var trashed: [URL] = []
        let result = DesktopCleaner.clean(directory: desktop, trash: { url in
            trashed.append(url)
            if url == first {
                try self.fileManager.moveItem(at: self.desktop, to: self.fixtureRoot.appendingPathComponent("OriginalDesktop"))
                try self.fileManager.createDirectory(at: self.desktop, withIntermediateDirectories: false)
                try Data("replacement".utf8).write(to: replacement)
            }
        })

        XCTAssertEqual(trashed, [first])
        XCTAssertEqual(result.trashedCount, 1)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].contains("Desktop folder changed"))
        XCTAssertEqual(try Data(contentsOf: replacement), Data("replacement".utf8))
    }
}

private final class ListingFileManager: FileManager, @unchecked Sendable {
    let listing: (URL) throws -> [URL]

    init(listing: @escaping (URL) throws -> [URL]) {
        self.listing = listing
        super.init()
    }

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        try listing(url)
    }
}
