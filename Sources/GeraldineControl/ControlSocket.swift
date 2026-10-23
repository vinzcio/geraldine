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
        guard bytes.count < capacity else { return nil }
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

    static func connect(path: String, timeout: TimeInterval = 0.2) -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return -1 }
        var tv = timeval(
            tv_sec: Int(max(0, timeout)),
            tv_usec: Int32((max(0, timeout) - Double(Int(max(0, timeout)))) * 1_000_000)
        )
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let result = ControlSocketAddress.withAddress(path: path) { address, length in
            Darwin.connect(descriptor, address, length)
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(descriptor)
            errno = code
            return -1
        }
        return descriptor
    }

    /// A successful connect proves a live server. The server sees the immediate
    /// close as an empty request and drops the connection.
    static func isLive(path: String, timeout: TimeInterval = 0.2) -> Bool {
        let descriptor = connect(path: path, timeout: timeout)
        guard descriptor >= 0 else { return false }
        Darwin.close(descriptor)
        return true
    }
}

public enum ControlServerError: Error, LocalizedError, Equatable {
    case pathTooLong
    case socketInUse(String)
    case couldNotCreateDirectory(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong:
            return "The control socket path is too long for a Unix socket."
        case .socketInUse(let path):
            return "Another Geraldine control server is already listening at \(path)."
        case .couldNotCreateDirectory(let path):
            return "Could not create the control directory at \(path)."
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
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vincent.geraldine.control-server", qos: .utility)
    private var listenDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    public private(set) var isRunning = false

    public init(socketURL: URL = ControlEndpoint.socketURL(), handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        guard !isRunning else { return }
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
        _ = chmod(directory.path, 0o700)

        if FileManager.default.fileExists(atPath: path) {
            if ControlSocketAddress.isLive(path: path) {
                throw ControlServerError.socketInUse(path)
            }
            unlink(path)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ControlServerError.socketFailed(errno) }

        let bound = ControlSocketAddress.withAddress(path: path) { address, length in
            Darwin.bind(descriptor, address, length)
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == ENAMETOOLONG { throw ControlServerError.pathTooLong }
            throw ControlServerError.bindFailed(code)
        }
        _ = chmod(path, 0o600)

        guard Darwin.listen(descriptor, 8) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            unlink(path)
            throw ControlServerError.listenFailed(code)
        }

        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        listenDescriptor = descriptor

        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptAvailable()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        self.source = source
        source.resume()
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        source?.cancel()
        source = nil
        listenDescriptor = -1
        unlink(socketURL.path)
    }

    private func acceptAvailable() {
        while isRunning, listenDescriptor >= 0 {
            let client = Darwin.accept(listenDescriptor, nil, nil)
            if client < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                return
            }

            var one: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            timeout = timeval(tv_sec: 120, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client: client)
            }
        }
    }

    private func handle(client: Int32) {
        var effectiveUID: uid_t = 0
        var effectiveGID: gid_t = 0
        guard getpeereid(client, &effectiveUID, &effectiveGID) == 0,
              effectiveUID == geteuid() else {
            Darwin.close(client)
            return
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= ControlProtocol.maximumLineBytes {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(client, raw.baseAddress, raw.count)
            }
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.contains(0x0A) { break }
        }

        guard let newline = data.firstIndex(of: 0x0A),
              let request = try? JSONDecoder().decode(ControlRequest.self, from: Data(data[..<newline])) else {
            let failed = ControlResponse.localFailure(
                command: "",
                code: .usage,
                message: "The control request was not valid JSON.",
                hint: "Send one newline-delimited JSON object that matches the control protocol."
            )
            write(failed, to: client)
            Darwin.close(client)
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
            write(failed, to: client)
            Darwin.close(client)
            return
        }

        Task { [handler] in
            let response = await handler(request)
            write(response, to: client)
            Darwin.close(client)
        }
    }

    private func write(_ response: ControlResponse, to client: Int32) {
        let line = response.encodedLine() + "\n"
        let bytes = Array(line.utf8)
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(client, base.advanced(by: offset), bytes.count - offset, 0)
            }
            if sent <= 0 { return }
            offset += sent
        }
    }
}

public enum ControlClientError: Error, LocalizedError, Equatable {
    case unavailable(Int32)
    case timedOut
    case malformedResponse
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .unavailable(let code):
            return "Could not connect to Geraldine's control socket (errno \(code))."
        case .timedOut:
            return "Geraldine did not answer the control request in time."
        case .malformedResponse:
            return "Geraldine returned a response that was not valid control JSON."
        case .responseTooLarge:
            return "Geraldine returned an oversized control response."
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

    public func send(_ request: ControlRequest, timeout: TimeInterval = 120) throws -> ControlResponse {
        let descriptor = ControlSocketAddress.connect(path: socketURL.path, timeout: timeout)
        guard descriptor >= 0 else {
            throw ControlClientError.unavailable(errno)
        }
        defer { Darwin.close(descriptor) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let payload = try? encoder.encode(request) else {
            throw ControlClientError.malformedResponse
        }
        var line = payload
        line.append(0x0A)

        var written = 0
        while written < line.count {
            let sent = line.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.send(descriptor, base.advanced(by: written), line.count - written, 0)
            }
            if sent <= 0 { throw ControlClientError.unavailable(errno) }
            written += sent
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = now().addingTimeInterval(timeout)
        while data.count <= ControlProtocol.maximumLineBytes {
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.recv(descriptor, raw.baseAddress, raw.count, 0)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    if now() >= deadline { throw ControlClientError.timedOut }
                    continue
                }
                if errno == EINTR { continue }
                throw ControlClientError.unavailable(errno)
            }
            data.append(contentsOf: buffer[0..<count])
            if data.contains(0x0A) { break }
        }

        guard data.count <= ControlProtocol.maximumLineBytes else {
            throw ControlClientError.responseTooLarge
        }
        guard let newline = data.firstIndex(of: 0x0A) else {
            throw ControlClientError.malformedResponse
        }
        guard let response = try? JSONDecoder().decode(ControlResponse.self, from: Data(data[..<newline])) else {
            throw ControlClientError.malformedResponse
        }
        return response
    }
}
