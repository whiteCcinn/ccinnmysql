import Darwin
import Foundation

/// Writes files readable only by the user, atomically: a 0600 temporary file next to the target (never readable by
/// others, even briefly), flushed, then renamed over the target. Used for knowledge bases and backups.
public enum PrivateFile {
    public struct WriteError: Error, LocalizedError, Sendable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(getpid())-\(UUID().uuidString.prefix(8))")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw WriteError(message: String(cString: strerror(errno))) }
        var failure: String?
        data.withUnsafeBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = String(cString: strerror(errno))
                    return
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
        if failure == nil, fsync(descriptor) != 0 { failure = String(cString: strerror(errno)) }
        close(descriptor)
        if failure == nil, rename(temporary.path, url.path) != 0 { failure = String(cString: strerror(errno)) }
        if let failure {
            unlink(temporary.path)
            throw WriteError(message: failure)
        }
    }
}
