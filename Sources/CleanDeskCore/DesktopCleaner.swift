import Darwin
import Foundation

public struct DesktopCleanupResult: Sendable {
    public let trashedCount: Int
    public let failures: [String]
    public let accessDenied: Bool

    public init(trashedCount: Int, failures: [String], accessDenied: Bool = false) {
        self.trashedCount = trashedCount
        self.failures = failures
        self.accessDenied = accessDenied
    }
}

public struct DesktopInspectionResult: Sendable {
    public let eligibleCount: Int
    public let failures: [String]
    public let accessDenied: Bool

    public init(eligibleCount: Int, failures: [String], accessDenied: Bool = false) {
        self.eligibleCount = eligibleCount
        self.failures = failures
        self.accessDenied = accessDenied
    }
}

/// Moves only visible, regular files directly on the Desktop to macOS Trash.
/// Directories, packages, aliases, symbolic links and hidden entries are preserved.
///
/// The directory and trash operation are injectable so tests never need the real
/// Desktop or Trash. Metadata is read afresh, without resolving links, and file and
/// directory identities are checked again immediately before each move. Foundation's
/// pathname-based trash API cannot make the final check and move atomic; this assumes
/// no concurrent replacement during that final API call. Observed changes are skipped.
public enum DesktopCleaner {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        .isHiddenKey, .isAliasFileKey, .isPackageKey,
    ]

    /// Reads the same candidates used by clean, without moving or modifying anything.
    /// A zero count with failures means inspection was incomplete, not an empty Desktop.
    public static func inspect(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> DesktopInspectionResult {
        let snapshot = scan(directory: directory, fileManager: fileManager)
        return DesktopInspectionResult(eligibleCount: snapshot.candidates.count, failures: snapshot.failures, accessDenied: snapshot.accessDenied)
    }

    private struct Scan {
        let root: URL?
        let originalRoot: FileStatus?
        let candidates: [(url: URL, status: FileStatus)]
        let failures: [String]
        let accessDenied: Bool

        static func failed(_ message: String, error: Error? = nil) -> Scan {
            Scan(root: nil, originalRoot: nil, candidates: [], failures: [message], accessDenied: error.map { isAccessDenied($0 as NSError) } ?? false)
        }
    }

    private static func scan(directory: URL?, fileManager: FileManager) -> Scan {
        guard let location = directory ?? fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first else {
            return .failed("The Desktop folder could not be found.")
        }
        guard location.isFileURL else {
            return .failed("The Desktop location is not a local folder.")
        }
        let root = location.standardizedFileURL
        let originalRoot: FileStatus
        do {
            originalRoot = try status(of: root)
            guard originalRoot.isDirectory else {
                return .failed("The Desktop location is not a folder. Nothing was moved.")
            }
        } catch {
            return .failed(message("Could not access the Desktop folder.", error: error), error: error)
        }

        let entries: [URL]
        do {
            // This enumerates one level only. Do not use DirectoryEnumerator here.
            entries = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [])
        } catch {
            return .failed(message("Could not read the Desktop folder.", error: error), error: error)
        }

        var failures: [String] = []
        var accessDenied = false
        var candidates: [(url: URL, status: FileStatus)] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                guard let child = try childURL(for: entry, under: root, rootIdentity: originalRoot.identity) else {
                    failures.append("An item outside the Desktop folder was skipped.")
                    continue
                }
                // Dot files remain untouched even when resource metadata is inaccessible.
                guard !child.lastPathComponent.hasPrefix(".") else { continue }
                if let initial = try eligibleStatus(of: child) {
                    candidates.append((child, initial))
                }
            } catch {
                accessDenied = accessDenied || isAccessDenied(error as NSError)
                failures.append(message("Could not inspect \"\(entry.lastPathComponent)\". It was left in place.", error: error))
            }
        }
        return Scan(root: root, originalRoot: originalRoot, candidates: candidates, failures: failures, accessDenied: accessDenied)
    }

    public static func clean(
        directory: URL? = nil,
        fileManager: FileManager = .default,
        trash: ((URL) throws -> Void)? = nil
    ) -> DesktopCleanupResult {
        let snapshot = scan(directory: directory, fileManager: fileManager)
        guard let root = snapshot.root, let originalRoot = snapshot.originalRoot else {
            return DesktopCleanupResult(trashedCount: 0, failures: snapshot.failures, accessDenied: snapshot.accessDenied)
        }
        var failures = snapshot.failures
        var accessDenied = snapshot.accessDenied
        let trashItem: (URL) throws -> Void = trash ?? { url in
            try fileManager.trashItem(at: url, resultingItemURL: nil)
        }
        var trashedCount = 0
        for candidate in snapshot.candidates {
            do {
                let currentRoot = try status(of: root)
                guard currentRoot.isDirectory, currentRoot.identity == originalRoot.identity else {
                    failures.append("The Desktop folder changed during cleanup. Remaining files were left in place.")
                    break
                }
                guard isDirectChild(candidate.url, of: root),
                      let current = try eligibleStatus(of: candidate.url),
                      current == candidate.status else {
                    failures.append("\"\(candidate.url.lastPathComponent)\" changed during cleanup and was left in place.")
                    continue
                }
            } catch {
                accessDenied = accessDenied || isAccessDenied(error as NSError)
                failures.append(message("Could not recheck \"\(candidate.url.lastPathComponent)\". It was left in place.", error: error))
                continue
            }

            do {
                try trashItem(candidate.url)
                trashedCount += 1
            } catch {
                accessDenied = accessDenied || isAccessDenied(error as NSError)
                failures.append(message("Could not move \"\(candidate.url.lastPathComponent)\" to Trash.", error: error))
            }
        }
        return DesktopCleanupResult(trashedCount: trashedCount, failures: failures, accessDenied: accessDenied)
    }

    private static func isDirectChild(_ url: URL, of root: URL) -> Bool {
        url.isFileURL && url.deletingLastPathComponent().path == root.path
            && url.path == root.appendingPathComponent(url.lastPathComponent).path
    }

    private static func childURL(for entry: URL, under root: URL, rootIdentity: Identity) throws -> URL? {
        guard entry.isFileURL, !entry.pathComponents.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        let name = entry.lastPathComponent
        let parent = entry.deletingLastPathComponent()
        guard !name.isEmpty, name != ".", name != "..", entry.path == parent.appendingPathComponent(name).path else { return nil }
        if parent.path != root.path {
            // Foundation can enumerate /var roots using /private/var URLs. Accept
            // a differently spelled parent only when it is the same real directory;
            // lstat still rejects a symbolic-link parent. Never resolve the entry.
            let parentStatus = try status(of: parent)
            guard parentStatus.isDirectory, parentStatus.identity == rootIdentity else { return nil }
        }
        return root.appendingPathComponent(name)
    }

    /// nil means intentionally excluded, while an error means eligibility could not be verified.
    private static func eligibleStatus(of url: URL) throws -> FileStatus? {
        let before = try status(of: url)
        guard before.isRegular, !before.isHidden else { return nil }
        var freshURL = URL(fileURLWithPath: url.path)
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: resourceKeys)
        // Some excluded resource kinds omit unrelated keys. A known exclusion
        // is enough to preserve the item; unknown eligibility must still fail shut.
        if values.isRegularFile == false || values.isDirectory == true || values.isSymbolicLink == true
            || values.isHidden == true || values.isAliasFile == true || values.isPackage == true {
            return nil
        }
        guard let regular = values.isRegularFile,
              let directory = values.isDirectory,
              let symbolicLink = values.isSymbolicLink,
              let hidden = values.isHidden,
              let alias = values.isAliasFile,
              let package = values.isPackage else {
            throw InspectionError.unknownMetadata
        }
        guard regular, !directory, !symbolicLink, !hidden, !alias, !package else { return nil }
        let after = try status(of: url)
        guard before == after else { throw InspectionError.changedDuringInspection }
        return after
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int
    }

    private struct FileStatus: Equatable {
        let identity: Identity
        let mode: mode_t
        let flags: UInt32
        let changeSeconds: Int
        let changeNanoseconds: Int

        var isDirectory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
        var isRegular: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
        var isHidden: Bool { flags & UInt32(UF_HIDDEN) != 0 }
    }

    private static func status(of url: URL) throws -> FileStatus {
        var info = stat()
        var errorCode = EINVAL
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            let result = Darwin.lstat(path, &info)
            if result != 0 { errorCode = errno }
            return result
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
        return FileStatus(
            identity: Identity(device: info.st_dev, inode: info.st_ino, birthSeconds: info.st_birthtimespec.tv_sec, birthNanoseconds: info.st_birthtimespec.tv_nsec),
            mode: info.st_mode,
            flags: info.st_flags,
            changeSeconds: info.st_ctimespec.tv_sec,
            changeNanoseconds: info.st_ctimespec.tv_nsec
        )
    }

    private enum InspectionError: Error {
        case unknownMetadata
        case changedDuringInspection
    }

    private static func message(_ text: String, error: Error) -> String {
        let cocoaError = error as NSError
        let reason = isAccessDenied(cocoaError) ? " macOS denied access." : ""
        return text + reason + " (\(cocoaError.domain) \(cocoaError.code))"
    }

    private static func isAccessDenied(_ error: NSError) -> Bool {
        if error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        if error.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isAccessDenied(underlying)
        }
        return false
    }
}
