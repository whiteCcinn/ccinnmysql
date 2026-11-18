import CryptoKit
import Darwin
import Foundation
import os

/// File names of knowledge bases (design D1).
public enum KnowledgeLocation {
    /// Longer encodings fall back to a hash (file names are limited to 255 bytes).
    static let maxEncodedLength = 180

    /// `[a-z0-9_-]` stays as is; every other byte, upper-case letters included, becomes `%XX`. Names that differ only in
    /// case get different files on a case-insensitive file system, and no Unicode normalization can merge two names.
    public static func fileName(for database: String) -> String {
        var encoded = ""
        encoded.reserveCapacity(database.utf8.count)
        for byte in database.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
                encoded.unicodeScalars.append(UnicodeScalar(byte))
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        if encoded.utf8.count > maxEncodedLength {
            let digest = SHA256.hash(data: Data(database.utf8)).map { String(format: "%02x", $0) }.joined()
            return "~" + digest + ".json"
        }
        return encoded + ".json"
    }

    /// The database a file name encodes, or `nil` for hashed names (read the file) and foreign files.
    public static func database(fromFileName fileName: String) -> String? {
        guard fileName.hasSuffix(".json"), !fileName.hasPrefix("~") else { return nil }
        let encoded = Array(fileName.utf8.dropLast(5))
        var bytes: [UInt8] = []
        bytes.reserveCapacity(encoded.count)
        var index = 0
        while index < encoded.count {
            let byte = encoded[index]
            if byte == UInt8(ascii: "%") {
                guard index + 2 < encoded.count, let value = UInt8(String(decoding: encoded[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) else {
                    return nil
                }
                bytes.append(value)
                index += 3
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

/// Persists knowledge bases (design D1, D2). Reads take no lock and are cached by file identity; writes are
/// read-modify-write under a per-file `flock`, so the app and several MCP processes can write the same knowledge base
/// without losing each other's changes, and different databases never contend.
public final class KnowledgeStore: Sendable {
    /// One knowledge base file of a connection.
    public struct Listing: Sendable {
        public let fileURL: URL
        /// From the file name, or from the file for hashed names (`nil` when that cannot be read either).
        public let database: String?
        public let knowledge: KnowledgeBase?
        public let error: String?
    }

    struct FileIdentity: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int

        init(_ info: stat) {
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    final class CacheEntry: @unchecked Sendable {
        let identity: FileIdentity
        let knowledge: KnowledgeBase
        /// Derived lazily; immutable once set (guarded by the store's cache lock).
        var graph: KnowledgeGraph?

        init(identity: FileIdentity, knowledge: KnowledgeBase) {
            self.identity = identity
            self.knowledge = knowledge
        }
    }

    public let root: URL
    let maxFileBytes: Int
    /// Guards only dictionary access; file I/O and decoding run outside the lock.
    private let cache = OSAllocatedUnfairLock<[KnowledgeKey: CacheEntry]>(initialState: [:])

    public static var defaultRoot: URL {
        ProfileRepository.defaultDirectory.appendingPathComponent("Knowledge", isDirectory: true)
    }

    public init(root: URL = KnowledgeStore.defaultRoot, maxFileBytes: Int = 64 * 1024 * 1024) {
        self.root = root
        self.maxFileBytes = maxFileBytes
    }

    public func directory(for connectionID: UUID) -> URL {
        root.appendingPathComponent(connectionID.uuidString, isDirectory: true)
    }

    public func fileURL(for key: KnowledgeKey) -> URL {
        directory(for: key.connectionID).appendingPathComponent(KnowledgeLocation.fileName(for: key.database))
    }

    // MARK: Reading

    /// The knowledge base, or `nil` when none was saved. Throws for unreadable, oversized or newer-format files.
    public func load(_ key: KnowledgeKey) throws -> KnowledgeBase? {
        try entry(key)?.knowledge
    }

    /// The knowledge base with its query graph (derived once per file version).
    public func loadWithGraph(_ key: KnowledgeKey) throws -> (knowledge: KnowledgeBase, graph: KnowledgeGraph)? {
        guard let entry = try entry(key) else { return nil }
        if let graph = cache.withLock({ _ in entry.graph }) { return (entry.knowledge, graph) }
        let graph = KnowledgeGraph(entry.knowledge)
        cache.withLock { _ in
            if entry.graph == nil { entry.graph = graph }
        }
        return (entry.knowledge, graph)
    }

    private func entry(_ key: KnowledgeKey) throws -> CacheEntry? {
        let url = fileURL(for: key)
        guard let (identity, data) = try read(url) else {
            cache.withLock { _ = $0.removeValue(forKey: key) }
            return nil
        }
        if let cached = cache.withLock({ $0[key] }), cached.identity == identity { return cached }
        let entry = CacheEntry(identity: identity, knowledge: try decode(data, url: url))
        cache.withLock { $0[key] = entry }
        return entry
    }

    /// Identity and contents of the file from one descriptor (so both describe the same version), `nil` if absent.
    /// The contents are read only when the identity differs from the cached one.
    private func read(_ url: URL) throws -> (FileIdentity, Data)? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw KnowledgeError("Could not open the knowledge base \(url.path): \(String(cString: strerror(errno))).", kind: .unavailable)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw KnowledgeError("Could not read the knowledge base \(url.path): \(String(cString: strerror(errno))).", kind: .unavailable)
        }
        guard info.st_size <= maxFileBytes else {
            throw KnowledgeError("The knowledge base \(url.path) is larger than \(maxFileBytes / 1_048_576) MB and was not read.", kind: .unavailable)
        }
        do {
            return (FileIdentity(info), try handle.readToEnd() ?? Data())
        } catch {
            throw KnowledgeError("Could not read the knowledge base \(url.path): \(error.localizedDescription).", kind: .unavailable)
        }
    }

    private struct Header: Decodable {
        let formatVersion: Int?
    }

    private func decode(_ data: Data, url: URL) throws -> KnowledgeBase {
        if let version = (try? JSONDecoder().decode(Header.self, from: data))?.formatVersion, version > KnowledgeBase.currentFormatVersion {
            throw KnowledgeError("The knowledge base \(url.lastPathComponent) was written by a newer version of CcinnMysql (format \(version)); update CcinnMysql to use it.",
                                 kind: .newerFormat)
        }
        do {
            return try JSONDecoder().decode(KnowledgeBase.self, from: data)
        } catch {
            throw KnowledgeError("The knowledge base \(url.path) cannot be read (\(error.localizedDescription)); it was left unchanged. Reset it in CcinnMysql to start over.",
                                 kind: .damaged)
        }
    }

    /// Every knowledge base file of a connection, readable or not.
    public func list(connectionID: UUID) -> [Listing] {
        let directory = directory(for: connectionID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().map { name in
            let url = directory.appendingPathComponent(name)
            let encoded = KnowledgeLocation.database(fromFileName: name)
            do {
                let knowledge: KnowledgeBase?
                if let encoded {
                    knowledge = try load(KnowledgeKey(connectionID: connectionID, database: encoded))
                } else {
                    knowledge = try read(url).map { try decode($0.1, url: url) }
                }
                return Listing(fileURL: url, database: knowledge?.database ?? encoded, knowledge: knowledge, error: nil)
            } catch {
                return Listing(fileURL: url, database: encoded, knowledge: nil, error: (error as? KnowledgeError)?.message ?? error.localizedDescription)
            }
        }
    }

    // MARK: Writing

    /// Runs `body` on the latest saved version under the file lock and saves the result when it changed (or when the
    /// knowledge base is created). An unreadable or newer-format file is never overwritten.
    @discardableResult
    public func update<T: Sendable>(_ key: KnowledgeKey, create: Bool = true, lockTimeout: Duration = .seconds(10),
                                    _ body: @Sendable (inout KnowledgeBase) throws -> T) async throws -> T {
        let url = fileURL(for: key)
        try prepareDirectories(for: key)
        let lock = try await FileLock.acquire(path: url.path + ".lock", timeout: lockTimeout)
        defer { lock.release() }
        let existing = try entry(key)?.knowledge
        guard existing != nil || create else {
            throw KnowledgeError("No knowledge base for database “\(key.database)” yet; build it first.")
        }
        var knowledge = existing ?? KnowledgeBase(key: key)
        let result = try body(&knowledge)
        if existing == nil || knowledge != existing {
            knowledge.updatedAt = Date()
            try write(knowledge, to: url, key: key)
        }
        return result
    }

    /// Moves the file aside (`<name>.corrupt-<time>`) so a fresh knowledge base can start; returns the moved file.
    @discardableResult
    public func reset(_ key: KnowledgeKey) async throws -> URL? {
        let url = fileURL(for: key)
        try prepareDirectories(for: key)
        let lock = try await FileLock.acquire(path: url.path + ".lock", timeout: .seconds(10))
        defer { lock.release() }
        cache.withLock { _ = $0.removeValue(forKey: key) }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4))")
        guard Darwin.rename(url.path, target.path) == 0 else {
            throw KnowledgeError("Could not move the knowledge base aside: \(String(cString: strerror(errno))).")
        }
        return target
    }

    private func prepareDirectories(for key: KnowledgeKey) throws {
        let directory = directory(for: key.connectionID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw KnowledgeError("Could not create \(directory.path): \(error.localizedDescription).")
        }
        // Owner-only, also when the folders existed before.
        chmod(root.path, 0o700)
        chmod(directory.path, 0o700)
    }

    /// Writes privately and atomically (`PrivateFile`), then caches what was written.
    private func write(_ knowledge: KnowledgeBase, to url: URL, key: KnowledgeKey) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(knowledge)
        } catch {
            throw KnowledgeError("Could not encode the knowledge base: \(error.localizedDescription).")
        }
        guard data.count <= maxFileBytes else {
            throw KnowledgeError("The knowledge base would exceed \(maxFileBytes / 1_048_576) MB and was not saved.")
        }
        do {
            try PrivateFile.write(data, to: url)
        } catch {
            throw KnowledgeError("Could not save the knowledge base: \(error.localizedDescription).")
        }
        var info = stat()
        if stat(url.path, &info) == 0 {
            let entry = CacheEntry(identity: FileIdentity(info), knowledge: knowledge)
            cache.withLock { $0[key] = entry }
        } else {
            cache.withLock { _ = $0.removeValue(forKey: key) }
        }
    }
}

/// An exclusive `flock` on a lock file, polled with `Task.sleep` so waiting never blocks a cooperative thread.
/// Each acquisition opens its own file description, so it excludes other processes and other tasks of this process alike.
final class FileLock {
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(path: String, timeout: Duration) async throws -> FileLock {
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw KnowledgeError("Could not open the lock file \(path): \(String(cString: strerror(errno))).")
        }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var delay = 1
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EINTR else {
                close(descriptor)
                throw KnowledgeError("Could not lock \(path): \(String(cString: strerror(code))).")
            }
            guard clock.now < deadline else {
                close(descriptor)
                throw KnowledgeError("The knowledge base is busy (another CcinnMysql process is saving it); try again.", kind: .unavailable)
            }
            do {
                try await Task.sleep(for: .milliseconds(delay))
            } catch {
                close(descriptor)
                throw error
            }
            delay = min(delay * 2, 25)
        }
        return FileLock(descriptor: descriptor)
    }

    /// Closing the descriptor releases the lock. Idempotent.
    func release() {
        guard descriptor >= 0 else { return }
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
