import Darwin
import Foundation

/// Advisory lock via flock(2). The kernel releases it when the process exits or crashes, so a stale lock file is harmless.
public final class FileLock {
    private var descriptor: Int32

    public init?(path: String) {
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        descriptor = fd
        ftruncate(fd, 0)
        let text = "\(getpid())\n"
        _ = text.withCString { write(fd, $0, strlen($0)) }
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}
