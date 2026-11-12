import Darwin
import Foundation

public struct NetworkInterface: Sendable, CustomStringConvertible {
    public var name: String
    public var address: IPv4Address
    public var netmask: IPv4Address
    public var index: UInt32

    public var description: String { "\(name)\t\(address)/\(netmask)" }

    /// IPv4, up, non-loopback interfaces.
    public static func all() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [NetworkInterface] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.ifa_netmask,
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            result.append(NetworkInterface(
                name: name,
                address: ipv4(addr),
                netmask: ipv4(mask),
                index: if_nametoindex(ifa.ifa_name)
            ))
        }
        return result
    }

    private static func ipv4(_ sa: UnsafeMutablePointer<sockaddr>) -> IPv4Address {
        sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            let v = UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            return IPv4Address([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
        }
    }
}

public enum ESPSocketError: Error, CustomStringConvertible {
    case system(String, Int32)
    case unknownInterface(String)

    public var description: String {
        switch self {
        case .system(let op, let e): return "\(op) failed: \(String(cString: strerror(e)))"
        case .unknownInterface(let n): return "unknown or down interface: \(n)"
        }
    }
}

/// UDP socket on port 3333 that broadcasts to 255.255.255.255, optionally pinned to one interface.
public final class ESPSocket {
    /// Sends from :3333 (like NMU). ODEs answer to 255.255.255.255:3330, so replies arrive on `rx`.
    private let tx: Int32
    private let rx: Int32
    public let interface: NetworkInterface?

    public init(interfaceName: String? = nil) throws {
        if let n = interfaceName {
            guard let i = NetworkInterface.all().first(where: { $0.name == n }) else {
                throw ESPSocketError.unknownInterface(n)
            }
            interface = i
        } else {
            interface = nil
        }

        tx = try ESPSocket.makeSocket(port: ESP.port, interface: interface)
        do {
            rx = try ESPSocket.makeSocket(port: ESP.replyPort, interface: interface)
        } catch {
            close(tx)
            throw error
        }
    }

    static func makeSocket(port: UInt16, interface: NetworkInterface?) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ESPSocketError.system("socket", errno) }

        var one: Int32 = 1
        let size = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, size)
        guard setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, size) == 0 else {
            let e = errno; close(fd); throw ESPSocketError.system("SO_BROADCAST", e)
        }
        if let i = interface {
            // Without this, 255.255.255.255 only leaves via the default-route interface.
            var idx = i.index
            guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
                let e = errno; close(fd); throw ESPSocketError.system("IP_BOUND_IF", e)
            }
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { let e = errno; close(fd); throw ESPSocketError.system("bind :\(port)", e) }
        return fd
    }

    deinit {
        close(tx)
        close(rx)
    }

    public func broadcast(_ packet: [UInt8]) throws {
        try send(packet, to: IPv4Address([255, 255, 255, 255]))
    }

    public func send(_ packet: [UInt8], to ip: IPv4Address) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ESP.port.bigEndian
        let b = ip.bytes
        addr.sin_addr.s_addr = (UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])).bigEndian
        let n = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(tx, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard n == packet.count else { throw ESPSocketError.system("sendto", errno) }
    }

    /// Receives datagrams until `timeout` elapses.
    public func receive(for timeout: TimeInterval, _ handler: ([UInt8], IPv4Address) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 2048)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return }
            var pfd = pollfd(fd: rx, events: Int16(POLLIN), revents: 0)
            let r = Darwin.poll(&pfd, 1, Int32(remaining * 1000))
            if r <= 0 { if r < 0 && errno == EINTR { continue }; return }
            var from = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { b in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(rx, b.baseAddress, b.count, 0, $0, &len) }
                }
            }
            if n <= 0 { continue }
            let v = UInt32(bigEndian: from.sin_addr.s_addr)
            let ip = IPv4Address([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
            handler(Array(buf[0..<n]), ip)
        }
    }
}
