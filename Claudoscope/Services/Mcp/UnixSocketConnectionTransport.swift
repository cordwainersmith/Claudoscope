import Foundation
import Logging
import MCP

enum McpSocketError: Error, CustomStringConvertible {
    case pathTooLong(String)
    case systemCall(String, Int32)
    case transportClosed

    var description: String {
        switch self {
        case .pathTooLong(let path):
            return "Socket path exceeds the unix sun_path limit (104 bytes): \(path)"
        case .systemCall(let call, let err):
            return "\(call) failed: \(String(cString: strerror(err)))"
        case .transportClosed:
            return "MCP socket transport is closed"
        }
    }
}

/// One accepted unix-socket connection, adapted to the MCP SDK's Transport
/// protocol. Framing is newline-delimited JSON, matching the SDK's
/// StdioTransport so the claudoscope-mcp shim can pump bytes verbatim.
actor UnixSocketConnectionTransport: Transport {
    nonisolated let logger: Logger

    private let fd: Int32
    private let queue: DispatchQueue
    private let onClose: @Sendable () -> Void

    private var readSource: DispatchSourceRead?
    private var messageStream: AsyncThrowingStream<Data, Swift.Error>?
    private var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
    private var isClosed = false

    init(fd: Int32, queue: DispatchQueue, onClose: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.queue = queue
        self.onClose = onClose
        self.logger = Logger(label: "com.claudoscope.mcp.transport")
    }

    func connect() async throws {
        guard readSource == nil, !isClosed else { return }

        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.messageStream = stream
        self.continuation = continuation

        let fd = self.fd
        let onClose = self.onClose
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        // The event handler runs serially on `queue`, so the capture-by-reference
        // buffer needs no further synchronization.
        var pending = Data()
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    pending.append(contentsOf: buffer[0..<n])
                    while let newlineIndex = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        let line = pending.subdata(in: pending.startIndex..<newlineIndex)
                        pending.removeSubrange(pending.startIndex...newlineIndex)
                        if !line.isEmpty {
                            continuation.yield(line)
                        }
                    }
                } else if n == 0 {
                    source.cancel()
                    return
                } else {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK { return }
                    if err == EINTR { continue }
                    source.cancel()
                    return
                }
            }
        }
        source.setCancelHandler {
            continuation.finish()
            close(fd)
            onClose()
        }
        source.resume()
        self.readSource = source
    }

    func disconnect() async {
        guard !isClosed else { return }
        isClosed = true
        if let source = readSource, !source.isCancelled {
            source.cancel()
        }
        readSource = nil
    }

    func send(_ data: Data) async throws {
        guard !isClosed else { throw McpSocketError.transportClosed }
        var payload = data
        payload.append(UInt8(ascii: "\n"))
        let fd = self.fd
        try payload.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = write(fd, base.advanced(by: offset), raw.count - offset)
                if n > 0 {
                    offset += n
                } else {
                    let err = errno
                    if err == EAGAIN || err == EWOULDBLOCK {
                        usleep(1000)
                        continue
                    }
                    if err == EINTR { continue }
                    throw McpSocketError.systemCall("write", err)
                }
            }
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        if let stream = messageStream {
            return stream
        }
        // receive() before connect(): return an already-finished stream.
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        continuation.finish()
        return stream
    }
}
