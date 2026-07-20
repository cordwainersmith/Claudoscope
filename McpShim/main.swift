// claudoscope-mcp — stdio <-> unix-socket byte proxy for the Claudoscope MCP
// server. MCP clients (Claude Code) run this as a stdio server; it forwards
// bytes verbatim to the socket served by the running Claudoscope app,
// launching the app first if needed.
//
// Usage: claudoscope-mcp [--socket <path>] [--timeout <seconds>] [--no-launch]

import Darwin
import Foundation

struct ShimOptions {
    var socketPath =
        NSHomeDirectory() + "/Library/Application Support/Claudoscope/mcp.sock"
    var timeoutSeconds = 15.0
    var launchApp = true
}

func parseArgs(_ args: [String]) -> ShimOptions {
    var options = ShimOptions()
    var index = 1
    while index < args.count {
        switch args[index] {
        case "--socket" where index + 1 < args.count:
            options.socketPath = args[index + 1]
            index += 2
        case "--timeout" where index + 1 < args.count:
            options.timeoutSeconds = Double(args[index + 1]) ?? options.timeoutSeconds
            index += 2
        case "--no-launch":
            options.launchApp = false
            index += 1
        default:
            FileHandle.standardError.write(Data("claudoscope-mcp: unknown argument \(args[index])\n".utf8))
            exit(2)
        }
    }
    return options
}

func connectOnce(path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }
    var noSigpipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let ok: Bool = withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        let bytes = Array(path.utf8)
        guard bytes.count < dst.count else { return false }
        dst.copyBytes(from: bytes)
        dst[bytes.count] = 0
        return true
    }
    guard ok else {
        close(fd)
        return -1
    }
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if result != 0 {
        close(fd)
        return -1
    }
    return fd
}

func launchApp() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-b", "com.claudoscope.app"]
    try? process.run()
    process.waitUntilExit()
}

func connectWithRetry(_ options: ShimOptions) -> Int32 {
    var fd = connectOnce(path: options.socketPath)
    if fd >= 0 { return fd }

    if options.launchApp {
        launchApp()
    }
    let deadline = Date().addingTimeInterval(options.timeoutSeconds)
    while Date() < deadline {
        usleep(200_000)
        fd = connectOnce(path: options.socketPath)
        if fd >= 0 { return fd }
    }
    FileHandle.standardError.write(Data(
        "claudoscope-mcp: could not connect to \(options.socketPath) within \(Int(options.timeoutSeconds))s. Is Claudoscope running with the MCP server enabled in Settings?\n".utf8
    ))
    exit(1)
}

/// Blocking read/write pump. Returns when the source hits EOF or either fd errors.
func pump(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(source, &buffer, buffer.count)
        if n == 0 { return }
        if n < 0 {
            if errno == EINTR { continue }
            return
        }
        var offset = 0
        while offset < n {
            let written = buffer.withUnsafeBytes { raw in
                write(destination, raw.baseAddress!.advanced(by: offset), n - offset)
            }
            if written > 0 {
                offset += written
            } else if errno != EINTR {
                return
            }
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let options = parseArgs(CommandLine.arguments)
let sock = connectWithRetry(options)

// stdin -> socket on a background thread; half-close the socket on stdin EOF
// so the server can finish any in-flight response before we exit.
let stdinThread = Thread {
    pump(from: 0, to: sock)
    shutdown(sock, SHUT_WR)
}
stdinThread.start()

// socket -> stdout on the main thread; socket EOF means the session is over.
pump(from: sock, to: 1)
exit(0)
