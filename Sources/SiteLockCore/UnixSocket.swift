#if canImport(Darwin)
import Darwin
import Foundation

public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    init(_ what: String) { description = "\(what): \(String(cString: strerror(errno)))" }
    init(message: String) { description = message }
}

/// Minimal blocking Unix-domain socket helpers for the one-request-per-connection protocol.
public enum UnixSocket {
    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else { throw SocketError(message: "socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        return addr
    }

    static func withSockaddr<T>(_ addr: inout sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Creates a listening socket at `path` (replacing a stale one) with the given file mode.
    public static func listen(path: String, mode: mode_t) throws -> Int32 {
        var addr = try address(path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        guard withSockaddr(&addr, { bind(fd, $0, $1) }) == 0 else { close(fd); throw SocketError("bind \(path)") }
        guard chmod(path, mode) == 0 else { close(fd); throw SocketError("chmod \(path)") }
        guard Darwin.listen(fd, 16) == 0 else { close(fd); throw SocketError("listen") }
        return fd
    }

    public static func connect(path: String, timeout: TimeInterval) throws -> Int32 {
        var addr = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket") }
        setTimeouts(fd, timeout)
        guard withSockaddr(&addr, { Darwin.connect(fd, $0, $1) }) == 0 else { close(fd); throw SocketError("connect \(path)") }
        return fd
    }

    public static func setTimeouts(_ fd: Int32, _ seconds: TimeInterval) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Reads up to and excluding the first "\n". Nil on EOF, timeout, oversize or when `deadline`
    /// passes (a total limit, so a client trickling bytes cannot hold the connection open).
    public static func readLine(_ fd: Int32, deadline: Date = .distantFuture) -> Data? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count <= Wire.maxMessageBytes && Date() < deadline {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { return nil }
            data.append(contentsOf: buf[0..<n])
            if let nl = data.firstIndex(of: 0x0A) { return data[data.startIndex..<nl] }
        }
        return nil
    }

    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { return false }
                offset += n
            }
            return true
        }
    }

    /// Client side: send one request, wait for one response.
    public static func send(_ request: Request, path: String = Paths.socket, timeout: TimeInterval = 30) throws -> Response {
        let fd = try connect(path: path, timeout: timeout)
        defer { close(fd) }
        guard writeAll(fd, try Wire.encode(request)) else { throw SocketError("write") }
        guard let line = readLine(fd) else { throw SocketError(message: "no response from sitelockd") }
        return try Wire.decode(Response.self, from: line)
    }
}
#endif
