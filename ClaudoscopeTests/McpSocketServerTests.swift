import XCTest
import MCP
@testable import Claudoscope

final class McpSocketServerTests: XCTestCase {
    private var socketURL: URL!
    private var server: McpSocketServer!

    override func setUp() {
        super.setUp()
        socketURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-test-\(UUID().uuidString.prefix(8)).sock")
    }

    override func tearDown() async throws {
        if let server {
            await server.stop()
        }
        try? FileManager.default.removeItem(at: socketURL)
        try await super.tearDown()
    }

    private func makeTestServer() -> @Sendable () async -> MCP.Server {
        return {
            let server = Server(
                name: "claudoscope-test",
                version: "0.0.1",
                capabilities: .init(tools: .init(listChanged: false))
            )
            await server.withMethodHandler(ListTools.self) { _ in
                .init(tools: [Tool(
                    name: "ping_tool",
                    description: "test tool",
                    inputSchema: ["type": "object"]
                )])
            }
            return server
        }
    }

    private func startServer() async throws {
        server = McpSocketServer(socketURL: socketURL, makeServer: makeTestServer())
        try await server.start()
    }

    // MARK: - Raw POSIX client helpers

    private func connectClient() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketURL.path
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            let bytes = Array(path.utf8)
            dst.copyBytes(from: bytes)
            dst[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw McpSocketError.systemCall("connect", errno)
        }
        return fd
    }

    private func sendLine(_ fd: Int32, _ line: String) {
        var data = Array(line.utf8)
        data.append(UInt8(ascii: "\n"))
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if n > 0 { offset += n } else if errno != EINTR { break }
        }
    }

    private func readLine(_ fd: Int32, timeout: TimeInterval = 5) -> String? {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var byte: UInt8 = 0
        while Date() < deadline {
            let n = read(fd, &byte, 1)
            if n == 1 {
                if byte == UInt8(ascii: "\n") {
                    return String(data: buffer, encoding: .utf8)
                }
                buffer.append(byte)
            } else if n == 0 {
                return nil
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                usleep(10_000)
            } else if errno != EINTR {
                return nil
            }
        }
        return nil
    }

    private func initializeRequest(id: Int) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"\(MCP.Version.latest)\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test-client\",\"version\":\"1.0\"}}}"
    }

    private func json(_ line: String?) throws -> [String: Any] {
        let data = try XCTUnwrap(line?.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Tests

    func testSocketCreatedWith0600Perms() async throws {
        try await startServer()
        let attrs = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.uint16Value
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual((attrs[.type] as? FileAttributeType), .typeSocket)
    }

    func testStaleSocketUnlinkedOnStart() async throws {
        // Plant a stale regular file where the socket goes.
        try Data("stale".utf8).write(to: socketURL)
        try await startServer()
        let attrs = try FileManager.default.attributesOfItem(atPath: socketURL.path)
        XCTAssertEqual((attrs[.type] as? FileAttributeType), .typeSocket)
    }

    func testInitializeAndToolsListRoundTrip() async throws {
        try await startServer()
        let fd = try connectClient()
        defer { close(fd) }

        sendLine(fd, initializeRequest(id: 1))
        let initResponse = try json(readLine(fd))
        XCTAssertEqual(initResponse["id"] as? Int, 1)
        let initResult = try XCTUnwrap(initResponse["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(initResult["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "claudoscope-test")

        sendLine(fd, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
        sendLine(fd, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")
        let toolsResponse = try json(readLine(fd))
        XCTAssertEqual(toolsResponse["id"] as? Int, 2)
        let toolsResult = try XCTUnwrap(toolsResponse["result"] as? [String: Any])
        let tools = try XCTUnwrap(toolsResult["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "ping_tool")
    }

    func testLargePayloadRoundTrip() async throws {
        // A tool description large enough to exercise partial writes on a
        // non-blocking fd (> socket buffer).
        let bigDescription = String(repeating: "x", count: 300_000)
        server = McpSocketServer(socketURL: socketURL, makeServer: {
            let server = Server(
                name: "claudoscope-test",
                version: "0.0.1",
                capabilities: .init(tools: .init(listChanged: false))
            )
            await server.withMethodHandler(ListTools.self) { _ in
                .init(tools: [Tool(name: "big", description: bigDescription, inputSchema: ["type": "object"])])
            }
            return server
        })
        try await server.start()

        let fd = try connectClient()
        defer { close(fd) }
        sendLine(fd, initializeRequest(id: 1))
        _ = readLine(fd)
        sendLine(fd, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
        sendLine(fd, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}")
        let toolsResponse = try json(readLine(fd, timeout: 10))
        let toolsResult = try XCTUnwrap(toolsResponse["result"] as? [String: Any])
        let tools = try XCTUnwrap(toolsResult["tools"] as? [[String: Any]])
        XCTAssertEqual((tools.first?["description"] as? String)?.count, 300_000)
    }

    func testClientEOFTearsDownConnection() async throws {
        try await startServer()
        let fd = try connectClient()
        sendLine(fd, initializeRequest(id: 1))
        _ = readLine(fd)
        var count = await server.clientCount
        XCTAssertEqual(count, 1)

        close(fd)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            count = await server.clientCount
            if count == 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(count, 0)
    }

    func testTwoConcurrentClients() async throws {
        try await startServer()
        let fd1 = try connectClient()
        let fd2 = try connectClient()
        defer { close(fd1); close(fd2) }

        sendLine(fd1, initializeRequest(id: 10))
        sendLine(fd2, initializeRequest(id: 20))
        let r1 = try json(readLine(fd1))
        let r2 = try json(readLine(fd2))
        XCTAssertEqual(r1["id"] as? Int, 10)
        XCTAssertEqual(r2["id"] as? Int, 20)

        sendLine(fd1, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
        sendLine(fd2, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}")
        sendLine(fd1, "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/list\"}")
        sendLine(fd2, "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tools/list\"}")
        XCTAssertEqual(try json(readLine(fd1))["id"] as? Int, 11)
        XCTAssertEqual(try json(readLine(fd2))["id"] as? Int, 21)

        let count = await server.clientCount
        XCTAssertEqual(count, 2)
    }

    func testClientCountCallbackFiresOnConnectAndDisconnect() async throws {
        final class CountBox: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Int] = []
            func append(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
            var latest: Int? { lock.lock(); defer { lock.unlock() }; return values.last }
            var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let box = CountBox()
        server = McpSocketServer(
            socketURL: socketURL,
            makeServer: makeTestServer(),
            onClientCountChange: { box.append($0) }
        )
        try await server.start()

        let fd = try connectClient()
        sendLine(fd, initializeRequest(id: 1))
        _ = readLine(fd)
        var deadline = Date().addingTimeInterval(5)
        while box.latest != 1 && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(box.latest, 1)

        close(fd)
        deadline = Date().addingTimeInterval(5)
        while box.latest != 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(box.latest, 0)
        XCTAssertEqual(box.all, [1, 0])
    }

    func testStopRemovesSocketFile() async throws {
        try await startServer()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        await server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        server = nil
    }
}
