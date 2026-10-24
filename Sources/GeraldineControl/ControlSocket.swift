import Foundation
import Darwin

public enum ControlEndpoint {
    public static let environmentKey = "GERALDINE_CONTROL_SOCKET"

    /// `~/Library/Application Support/Geraldine/control.sock`, unless a test or
    /// a launch wrapper overrides it.
    public static func socketURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support
            .appendingPathComponent("Geraldine", isDirectory: true)
            .appendingPathComponent("control.sock", isDirectory: false)
    }
}

enum ControlSocketAddress {
    static func withAddress<T>(path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !bytes.contains(0) else { errno = EINVAL; return nil }
        guard bytes.count < capacity else { errno = ENAMETOOLONG; return nil }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func makeDescriptor() -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return -1 }
        var noSignal: Int32 = 1
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            errno = code
            return -1
        }
        return descriptor
    }

    static func connect(path: String, timeout: TimeInterval? = nil) -> Int32 {
        if let timeout, !timeout.isFinite || timeout <= 0 { errno = EINVAL; return -1 }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        let descriptor = makeDescriptor()
        guard descriptor >= 0 else { return -1 }
        let result = ControlSocketAddress.withAddress(path: path) { address, length in
            Darwin.connect(descriptor, address, length)
        }
        if result != 0 {
            let code = errno
            guard result != nil, code == EINPROGRESS,
                  waitUntilReady(descriptor, events: Int16(POLLOUT), deadline: deadline) else {
                let failure = errno
                Darwin.close(descriptor)
                errno = failure
                return -1
            }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
                let failure = error == 0 ? errno : error
                Darwin.close(descriptor)
                errno = failure
                return -1
            }
        }
        return descriptor
    }

    static func waitUntilReady(_ descriptor: Int32, events: Int16, deadline: Date?, now: () -> Date = Date.init) -> Bool {
        while true {
            var milliseconds: Int32 = -1 // no caller-selected deadline
            if let deadline {
                let remaining = deadline.timeIntervalSince(now())
                guard remaining > 0 else { errno = ETIMEDOUT; return false }
                // Chunk only for poll's integer representation, with no
                // product limit on the caller's selected timeout.
                milliseconds = remaining >= Double(Int32.max) / 1_000
                    ? Int32.max : Int32(max(1, ceil(remaining * 1_000)))
            }
            var event = pollfd(fd: descriptor, events: events, revents: 0)
            let ready = Darwin.poll(&event, 1, milliseconds)
            if ready < 0, errno == EINTR { continue }
            if ready < 0 { return false }
            if ready == 0 { continue }
            if event.revents & Int16(POLLNVAL) != 0 { errno = EBADF; return false }
            return true
        }
    }

    /// No wait and no guessed liveness deadline: only ECONNREFUSED proves a
    /// stale socket. A pending or uncertain connection must be preserved.
    static func probe(path: String) -> Int32 {
        let descriptor = makeDescriptor()
        guard descriptor >= 0 else { return errno }
        let result = withAddress(path: path) { Darwin.connect(descriptor, $0, $1) }
        let code = result == 0 ? 0 : errno
        Darwin.close(descriptor)
        return code
    }
}

public enum ControlServerError: Error, LocalizedError, Equatable {
    case pathTooLong
    case socketInUse(String)
    case couldNotCreateDirectory(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case unsafePath(String)
    case fileOperationFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong:
            return "The control socket path is too long for a Unix socket."
        case .socketInUse(let path):
            return "Another Geraldine control server is already listening at \(path)."
        case .couldNotCreateDirectory(let path):
            return "Could not create the control directory at \(path)."
        case .unsafePath(let path):
            return "The control path requires an owned directory with mode 0700 and an owned socket, without symlinks: \(path). Existing permissions were not changed."
        case .fileOperationFailed(let path, let code):
            return "Could not safely prepare the control path at \(path) (errno \(code))."
        case .socketFailed(let code), .bindFailed(let code), .listenFailed(let code):
            return "The control socket failed with errno \(code)."
        }
    }
}

/// Newline-delimited JSON over a Unix-domain socket. The listener uses a
/// dispatch read source, so it consumes no CPU while idle. Request handling is
/// asynchronous so scans and thermal reads never block the accept loop.
public final class ControlServer {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    public let socketURL: URL
    private let defaultDirectoryURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vincent.geraldine.control-server", qos: .utility)
    private let stateLock = NSLock()
    private var listenDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var generation: UUID?
    private var socketIdentity: SocketIdentity?
    private var directoryDescriptor: Int32 = -1
    private var clients: [UUID: ControlConnection] = [:]
    public var isRunning: Bool { stateLock.withLock { source != nil } }

    private struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    public convenience init(socketURL: URL = ControlEndpoint.socketURL(), handler: @escaping Handler) {
        self.init(socketURL: socketURL,
                  defaultDirectoryURL: ControlEndpoint.socketURL(environment: [:]).deletingLastPathComponent(),
                  handler: handler)
    }

    /// Internal only so tests can model the app-owned default directory without
    /// changing the real Application Support directory. A public custom socket
    /// never grants permission to repair its containing directory.
    init(socketURL: URL, defaultDirectoryURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.defaultDirectoryURL = defaultDirectoryURL.standardizedFileURL
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard source == nil else { return }
        let path = socketURL.path
        let directory = socketURL.deletingLastPathComponent()
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw ControlServerError.pathTooLong
        }

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw ControlServerError.couldNotCreateDirectory(directory.path)
        }
        // O_NOFOLLOW rejects a symlink at the parent itself. Custom directory
        // permissions are never repaired.
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw ControlServerError.fileOperationFailed(directory.path, errno) }
        var keepParent = false
        defer { if !keepParent { Darwin.close(parent) } }
        var directoryInfo = stat()
        guard fstat(parent, &directoryInfo) == 0 else {
            throw ControlServerError.fileOperationFailed(directory.path, errno)
        }
        guard directoryInfo.st_uid == geteuid() else {
            throw ControlServerError.unsafePath(directory.path)
        }
        // Vincent approved only this future-startup upgrade: the app's own
        // default directory may move from 0755 to 0700. Do not generalize this
        // to custom directories or other pre-existing permission modes.
        if directory.standardizedFileURL == defaultDirectoryURL, directoryInfo.st_mode & 0o7777 == 0o755 {
            var current = stat()
            guard lstat(directory.path, &current) == 0,
                  current.st_mode & S_IFMT == S_IFDIR, current.st_uid == geteuid(),
                  SocketIdentity(current) == SocketIdentity(directoryInfo) else {
                throw ControlServerError.unsafePath(directory.path)
            }
            guard fchmod(parent, 0o700) == 0 else {
                throw ControlServerError.fileOperationFailed(directory.path, errno)
            }
            guard fstat(parent, &directoryInfo) == 0 else {
                throw ControlServerError.fileOperationFailed(directory.path, errno)
            }
        }
        guard directoryInfo.st_mode & 0o777 == 0o700 else {
            throw ControlServerError.unsafePath(directory.path)
        }
        // Serialize cooperating starters through bind/chmod/listen. Without
        // this, a second starter can mistake the first one's just-bound socket
        // (not listening yet) for a stale crash artifact. No lock file is needed.
        guard flock(parent, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw ControlServerError.socketInUse(path) }
            throw ControlServerError.fileOperationFailed(directory.path, errno)
        }
        defer { _ = flock(parent, LOCK_UN) }

        let name = socketURL.lastPathComponent
        var existing = stat()
        if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFSOCK, existing.st_uid == geteuid() else {
                throw ControlServerError.unsafePath(path)
            }
            let probeError = ControlSocketAddress.probe(path: path)
            if probeError == 0 { throw ControlServerError.socketInUse(path) }
            // Permission errors and resource exhaustion do not prove staleness.
            guard probeError == ECONNREFUSED else {
                throw ControlServerError.fileOperationFailed(path, probeError)
            }
            var current = stat()
            guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  SocketIdentity(current) == SocketIdentity(existing),
                  unlinkat(parent, name, 0) == 0 else {
                throw ControlServerError.fileOperationFailed(path, errno)
            }
        } else if errno != ENOENT {
            throw ControlServerError.fileOperationFailed(path, errno)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlServerError.socketFailed(errno) }
        var keepDescriptor = false
        defer { if !keepDescriptor { Darwin.close(descriptor) } }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw ControlServerError.socketFailed(errno)
        }

        let bound = ControlSocketAddress.withAddress(path: path) { address, length in
            Darwin.bind(descriptor, address, length)
        }
        guard bound == 0 else {
            let code = errno
            if code == ENAMETOOLONG { throw ControlServerError.pathTooLong }
            throw ControlServerError.bindFailed(code)
        }
        var boundInfo = stat()
        guard fstatat(parent, name, &boundInfo, AT_SYMLINK_NOFOLLOW) == 0,
              boundInfo.st_mode & S_IFMT == S_IFSOCK, boundInfo.st_uid == geteuid() else {
            throw ControlServerError.unsafePath(path)
        }
        let identity = SocketIdentity(boundInfo)
        var keepSocket = false
        defer {
            if !keepSocket { removeSocketIfOwned(parent: parent, identity: identity) }
        }
        guard fchmodat(parent, name, 0o600, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ControlServerError.fileOperationFailed(path, errno)
        }

        guard Darwin.listen(descriptor, SOMAXCONN) == 0 else {
            let code = errno
            throw ControlServerError.listenFailed(code)
        }

        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw ControlServerError.socketFailed(errno)
        }
        listenDescriptor = descriptor
        let generation = UUID()
        self.generation = generation

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailable(generation: generation)
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        self.source = source
        directoryDescriptor = parent
        socketIdentity = identity
        keepParent = true
        keepDescriptor = true
        keepSocket = true
        source.resume()
    }

    public func stop() {
        stateLock.lock()
        guard source != nil else { stateLock.unlock(); return }
        source?.cancel()
        source = nil
        listenDescriptor = -1
        generation = nil
        let connections = Array(clients.values)
        clients.removeAll()
        if let identity = socketIdentity {
            removeSocketIfOwned(parent: directoryDescriptor, identity: identity)
        }
        Darwin.close(directoryDescriptor)
        directoryDescriptor = -1
        socketIdentity = nil
        stateLock.unlock()
        for connection in connections { connection.cancel() }
    }

    private func removeSocketIfOwned(parent: Int32, identity: SocketIdentity) {
        var current = stat()
        let name = socketURL.lastPathComponent
        if fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
           current.st_mode & S_IFMT == S_IFSOCK, current.st_uid == geteuid(),
           SocketIdentity(current) == identity {
            _ = unlinkat(parent, name, 0)
        }
    }

    private func acceptAvailable(generation expectedGeneration: UUID) {
        while true {
            stateLock.lock()
            guard generation == expectedGeneration, listenDescriptor >= 0 else {
                stateLock.unlock()
                return
            }
            let client = Darwin.accept(listenDescriptor, nil, nil)
            if client < 0 {
                let code = errno
                stateLock.unlock()
                if code == EAGAIN || code == EWOULDBLOCK { return }
                if code == EINTR { continue }
                return
            }

            var one: Int32 = 1
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == geteuid(),
                  fcntl(client, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(client, F_SETFD, FD_CLOEXEC) == 0,
                  setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                Darwin.close(client)
                stateLock.unlock()
                continue
            }
            let id = UUID()
            let connection = ControlConnection(descriptor: client, queue: queue, handler: handler) { [weak self] in
                self?.stateLock.withLock { self?.clients[id] = nil }
            }
            clients[id] = connection
            connection.start()
            stateLock.unlock()
        }
    }
}

/// A single request owns its task and descriptor. All I/O/lifecycle transitions
/// run on one serial queue; only the read source's cancel handler closes the FD.
/// EOF remains observed while the async app handler is suspended.
private final class ControlConnection: @unchecked Sendable {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private let handler: ControlServer.Handler
    private let onClose: () -> Void
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var handlerTask: Task<Void, Never>?
    private var receivedRequest = false
    private var finished = false
    private var input = Data()
    private var output = Data()
    private var written = 0

    init(descriptor: Int32, queue: DispatchQueue, handler: @escaping ControlServer.Handler, onClose: @escaping () -> Void) {
        self.descriptor = descriptor
        self.queue = queue
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [descriptor, onClose] in
            Darwin.close(descriptor)
            onClose()
        }
        reader = source
        source.resume()
    }

    func cancel() {
        queue.async { [self] in finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        handlerTask?.cancel()
        handlerTask = nil
        writer?.cancel()
        writer = nil
        reader?.cancel()
        reader = nil
    }

    private func readAvailable() {
        guard !finished else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !finished {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.recv(descriptor, raw.baseAddress, raw.count, 0)
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                finish()
                return
            }
            if count == 0 { finish(); return }
            if receivedRequest { continue } // Drain extra input while observing EOF.
            // Search each new chunk once, never the entire growing request.
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                input.append(contentsOf: buffer[..<newline])
                receivedRequest = true
                dispatchRequest()
                input = Data()
            } else {
                input.append(contentsOf: buffer[..<count])
            }
        }
    }

    private func dispatchRequest() {
        guard let request = try? JSONDecoder().decode(ControlRequest.self, from: input) else {
            let failed = ControlResponse.localFailure(
                command: "",
                code: .usage,
                message: "The control request was not valid JSON.",
                hint: "Send one newline-delimited JSON object that matches the control protocol."
            )
            send(failed)
            return
        }

        guard request.protocolVersion == ControlProtocol.version else {
            let failed = ControlResponse.localFailure(
                id: request.id,
                command: request.command,
                code: .unsupported,
                message: "Control protocol \(request.protocolVersion) is not supported by this build.",
                hint: "Update the CLI and Geraldine so both use protocol \(ControlProtocol.version)."
            )
            send(failed)
            return
        }

        handlerTask = Task { [weak self, handler] in
            guard !Task.isCancelled else { return }
            let response = await handler(request)
            guard !Task.isCancelled else { return }
            self?.queue.async { [weak self] in self?.send(response) }
        }
    }

    private func send(_ response: ControlResponse) {
        guard !finished else { return }
        output = Data((response.encodedLine() + "\n").utf8)
        writeAvailable()
    }

    private func writeAvailable() {
        guard !finished else { return }
        while written < output.count {
            let sent = output.withUnsafeBytes { raw in
                Darwin.send(descriptor, raw.baseAddress!.advanced(by: written), output.count - written, 0)
            }
            if sent < 0, errno == EINTR { continue }
            if sent < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                    source.setEventHandler { [weak self] in self?.writeAvailable() }
                    writer = source
                    source.resume()
                }
                return
            }
            if sent <= 0 { finish(); return }
            written += sent
        }
        finish()
    }
}

public enum ControlClientError: Error, LocalizedError, Equatable {
    case unavailable(Int32)
    case transportFailed(Int32)
    case untrustedPeer
    case invalidTimeout
    case timedOut
    case malformedResponse
    case unsupportedProtocol(Int)
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let code):
            return "Could not connect to Geraldine's control socket (errno \(code))."
        case .transportFailed(let code):
            return "The control connection failed (errno \(code)); the request's result is unknown."
        case .untrustedPeer:
            return "The control server does not belong to the current user."
        case .invalidTimeout:
            return "The control timeout must be a finite positive number of seconds."
        case .timedOut:
            return "Geraldine did not answer the control request in time."
        case .malformedResponse:
            return "Geraldine returned a response that was not valid control JSON."
        case .unsupportedProtocol(let version):
            return "The server returned unsupported control protocol \(version)."
        case .unsupportedSchema(let version):
            return "The server returned unsupported response schema \(version)."
        }
    }
}

public struct ControlClient {
    public let socketURL: URL
    private let now: () -> Date

    public init(socketURL: URL = ControlEndpoint.socketURL(), now: @escaping () -> Date = Date.init) {
        self.socketURL = socketURL
        self.now = now
    }

    public func send(_ request: ControlRequest, timeout: TimeInterval? = nil) throws -> ControlResponse {
        if let timeout, !timeout.isFinite || timeout <= 0 { throw ControlClientError.invalidTimeout }
        let deadline = timeout.map { now().addingTimeInterval($0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(request)
        line.append(0x0A)
        let descriptor = ControlSocketAddress.connect(path: socketURL.path, timeout: try remaining(until: deadline))
        guard descriptor >= 0 else {
            if errno == ETIMEDOUT { throw ControlClientError.timedOut }
            throw ControlClientError.unavailable(errno)
        }
        defer { Darwin.close(descriptor) }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            throw ControlClientError.untrustedPeer
        }

        var written = 0
        while written < line.count {
            _ = try remaining(until: deadline)
            let sent = line.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(descriptor, base.advanced(by: written), line.count - written, 0)
            }
            if sent < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                    continue
                }
                throw ControlClientError.transportFailed(errno)
            }
            if sent == 0 { throw ControlClientError.transportFailed(EPIPE) }
            written += sent
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var newline: Data.Index?
        while newline == nil {
            _ = try remaining(until: deadline)
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.recv(descriptor, raw.baseAddress, raw.count, 0)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
                    continue
                }
                if errno == EINTR { continue }
                throw ControlClientError.transportFailed(errno)
            }
            if let offset = buffer[..<count].firstIndex(of: 0x0A) {
                newline = data.endIndex + offset
            }
            data.append(contentsOf: buffer[..<count])
        }
        guard let newline else {
            throw ControlClientError.malformedResponse
        }
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: Data(data[..<newline])) else {
            throw ControlClientError.malformedResponse
        }
        guard response.protocolVersion == ControlProtocol.version else {
            throw ControlClientError.unsupportedProtocol(response.protocolVersion)
        }
        guard response.schemaVersion == ControlProtocol.schemaVersion else {
            throw ControlClientError.unsupportedSchema(response.schemaVersion)
        }
        guard response.id == request.id, response.command == request.command,
              response.ok == (response.error == nil) else { throw ControlClientError.malformedResponse }
        _ = try remaining(until: deadline)
        return response
    }

    private func remaining(until deadline: Date?) throws -> TimeInterval? {
        guard let deadline else { return nil }
        let remaining = deadline.timeIntervalSince(now())
        guard remaining > 0 else { throw ControlClientError.timedOut }
        return remaining
    }

    private func wait(_ descriptor: Int32, events: Int16, deadline: Date?) throws {
        guard ControlSocketAddress.waitUntilReady(descriptor, events: events, deadline: deadline, now: now) else {
            if errno == ETIMEDOUT { throw ControlClientError.timedOut }
            throw ControlClientError.transportFailed(errno)
        }
    }
}
