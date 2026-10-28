import Darwin
import Foundation

/// A process-scoped lease for one local app instance. The file deliberately
/// stays in place after release: deleting it could let a second inode be locked
/// while another process still holds the original lock.
public final class SingleInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// Returns nil only when another instance holds the lock. A leftover file
    /// from a crash is harmless; the kernel releases locks when a process exits.
    public static func acquire(at url: URL) throws -> SingleInstanceLock? {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let descriptor = url.path.withCString {
            Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixError(errno, url: url) }

        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                return SingleInstanceLock(descriptor: descriptor)
            }
            let error = errno
            if error == EINTR { continue }
            Darwin.close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN { return nil }
            throw posixError(error, url: url)
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }

    private static func posixError(_ code: Int32, url: URL) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
    }
}
