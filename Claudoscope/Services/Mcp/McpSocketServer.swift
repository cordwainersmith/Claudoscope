import Foundation
import MCP

/// Listens on a unix domain socket and runs one MCP Server per accepted
/// connection (the SDK's model is 1 transport == 1 session). The socket is
/// created 0600 so only the local user can connect.
actor McpSocketServer {
    private let socketURL: URL
    private let makeServer: @Sendable () async -> MCP.Server
    private let onClientCountChange: (@Sendable (Int) -> Void)?

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: (server: MCP.Server, transport: UnixSocketConnectionTransport)] = [:]
    private let ioQueue = DispatchQueue(label: "com.claudoscope.mcp.io")

    init(
        socketURL: URL,
        makeServer: @escaping @Sendable () async -> MCP.Server,
        onClientCountChange: (@Sendable (Int) -> Void)? = nil
    ) {
        self.socketURL = socketURL
        self.makeServer = makeServer
        self.onClientCountChange = onClientCountChange
    }

    var clientCount: Int { connections.count }
    var isRunning: Bool { listenFD >= 0 }

    func start() throws {
        guard listenFD < 0 else { return }

        let path = socketURL.path
        guard path.utf8.count < 104 else { throw McpSocketError.pathTooLong(path) }
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw McpSocketError.systemCall("socket", errno) }

        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let copied: Bool = withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let bytes = Array(path.utf8)
            guard bytes.count < dst.count else { return false }
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
            return true
        }
        guard copied else {
            close(fd)
            throw McpSocketError.pathTooLong(path)
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(fd)
            throw McpSocketError.systemCall("bind", err)
        }

        chmod(path, 0o600)

        guard listen(fd, 8) == 0 else {
            let err = errno
            close(fd)
            unlink(path)
            throw McpSocketError.systemCall("listen", err)
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.acceptPending() }
        }
        source.resume()
        acceptSource = source
    }

    func stop() async {
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        let open = connections
        connections = [:]
        for (_, entry) in open {
            // stop() cancels the message loop and disconnects the transport,
            // which closes the client fd; disconnect is idempotent.
            await entry.server.stop()
        }
        unlink(socketURL.path)
        onClientCountChange?(0)
    }

    private func acceptPending() async {
        while listenFD >= 0 {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                let err = errno
                if err == EINTR { continue }
                return  // EAGAIN/EWOULDBLOCK: drained; anything else: give up this round
            }
            await setUpConnection(clientFD)
        }
    }

    private func setUpConnection(_ clientFD: Int32) async {
        let transport = UnixSocketConnectionTransport(fd: clientFD, queue: ioQueue) { [weak self] in
            Task { await self?.connectionClosed(clientFD) }
        }
        let server = await makeServer()
        connections[clientFD] = (server, transport)
        do {
            try await server.start(transport: transport)
        } catch {
            connections[clientFD] = nil
            await transport.disconnect()
        }
        onClientCountChange?(connections.count)
    }

    private func connectionClosed(_ clientFD: Int32) async {
        guard let entry = connections.removeValue(forKey: clientFD) else { return }
        await entry.server.stop()
        onClientCountChange?(connections.count)
    }
}
