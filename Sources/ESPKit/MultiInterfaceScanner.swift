import Darwin
import Foundation

/// Polls on every IPv4 interface at once and reports which interface each reply arrived on.
///
/// One send socket per interface (IP_BOUND_IF, so 255.255.255.255 leaves through that NIC) and a
/// single unbound receive socket on :3330 with IP_RECVIF to recover the arrival interface.
public final class MultiInterfaceScanner {
    public struct Hit: Sendable {
        public var node: DiscoveredNode
        public var interfaceName: String
    }

    private var tx: [(name: String, fd: Int32)] = []
    private let rx: Int32
    /// Interfaces whose socket could not be set up (e.g. tunnels without broadcast).
    public private(set) var failures: [String: Error] = [:]

    public init(interfaceNames: [String]? = nil) throws {
        var seen = Set<String>()
        let all = NetworkInterface.all().filter { seen.insert($0.name).inserted }
        let chosen = interfaceNames.map { names in all.filter { names.contains($0.name) } } ?? all
        for i in chosen {
            do { tx.append((i.name, try ESPSocket.makeSocket(port: ESP.port, interface: i))) } catch { failures[i.name] = error }
        }
        rx = try ESPSocket.makeSocket(port: ESP.replyPort, interface: nil)
        var one: Int32 = 1
        guard setsockopt(rx, IPPROTO_IP, IP_RECVIF, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            let e = errno
            close(rx); tx.forEach { close($0.fd) }
            throw ESPSocketError.system("IP_RECVIF", e)
        }
    }

    deinit {
        close(rx)
        tx.forEach { close($0.fd) }
    }

    public func discover(timeout: TimeInterval = 1.5, replyType: UInt8 = 0x01) -> [Hit] {
        let poll = PacketCodec.poll(replyType: replyType)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = ESP.port.bigEndian
        addr.sin_addr.s_addr = INADDR_BROADCAST
        for (name, fd) in tx {
            let n = poll.withUnsafeBytes { buf in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            if n < 0 { failures[name] = ESPSocketError.system("sendto", errno) }
        }

        var hits: [MACAddress: Hit] = [:]
        let addrs = NetworkInterface.all()
        // Same-subnet NIC is the natural "home" of a node; otherwise keep the first NIC it was heard on.
        func onSubnet(_ ifName: String, _ ip: IPv4Address) -> Bool {
            addrs.contains { i in
                i.name == ifName && zip(zip(i.address.bytes, i.netmask.bytes), ip.bytes).allSatisfy { ($0.0 & $0.1) == ($1 & $0.1) }
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        var buf = [UInt8](repeating: 0, count: 2048)
        var control = [UInt8](repeating: 0, count: 256)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            var pfd = pollfd(fd: rx, events: Int16(POLLIN), revents: 0)
            let r = Darwin.poll(&pfd, 1, Int32(remaining * 1000))
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { break }

            var from = sockaddr_in()
            var ifIndex: UInt32 = 0
            let n: Int = buf.withUnsafeMutableBytes { b in
                control.withUnsafeMutableBytes { c in
                    withUnsafeMutablePointer(to: &from) { fromPtr in
                        var iov = iovec(iov_base: b.baseAddress, iov_len: b.count)
                        return withUnsafeMutablePointer(to: &iov) { iovPtr in
                            var msg = msghdr(msg_name: UnsafeMutableRawPointer(fromPtr),
                                             msg_namelen: socklen_t(MemoryLayout<sockaddr_in>.size),
                                             msg_iov: iovPtr, msg_iovlen: 1,
                                             msg_control: c.baseAddress, msg_controllen: socklen_t(c.count),
                                             msg_flags: 0)
                            let got = recvmsg(rx, &msg, 0)
                            if got > 0 { ifIndex = Self.recvInterfaceIndex(&msg) }
                            return got
                        }
                    }
                }
            }
            if n <= 0 { continue }
            let data = Array(buf[0..<n])
            guard let g = PacketCodec.parseGenericPollReply(data) else { continue }
            let v = UInt32(bigEndian: from.sin_addr.s_addr)
            let ip = IPv4Address([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
            var nameBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
            let ifName = (ifIndex != 0 && if_indextoname(ifIndex, &nameBuf) != nil) ? String(cString: nameBuf) : "?"
            let node = DiscoveredNode(mac: g.mac, nodeType: g.nodeType, firmware: g.firmware, shortName: g.shortName,
                                      ip: ip, ode: PacketCodec.parseODEPollReply(data, sourceIP: ip))
            if let prev = hits[g.mac], prev.interfaceName != ifName,
               onSubnet(prev.interfaceName, ip) || !onSubnet(ifName, ip) {
                continue
            }
            hits[g.mac] = Hit(node: node, interfaceName: ifName)
        }
        return hits.values.sorted { $0.node.mac.description < $1.node.mac.description }
    }

    private static func recvInterfaceIndex(_ msg: inout msghdr) -> UInt32 {
        guard msg.msg_controllen > 0, let base = msg.msg_control else { return 0 }
        var offset = 0
        let total = Int(msg.msg_controllen)
        let align = MemoryLayout<UInt32>.size  // __DARWIN_ALIGN32
        while offset + MemoryLayout<cmsghdr>.size <= total {
            let hdr = base.advanced(by: offset).assumingMemoryBound(to: cmsghdr.self).pointee
            if hdr.cmsg_len == 0 { break }
            let headerLen = (MemoryLayout<cmsghdr>.size + align - 1) & ~(align - 1)
            if hdr.cmsg_level == IPPROTO_IP, hdr.cmsg_type == IP_RECVIF {
                let dl = base.advanced(by: offset + headerLen).assumingMemoryBound(to: sockaddr_dl.self).pointee
                return UInt32(dl.sdl_index)
            }
            offset += (Int(hdr.cmsg_len) + align - 1) & ~(align - 1)
        }
        return 0
    }
}
