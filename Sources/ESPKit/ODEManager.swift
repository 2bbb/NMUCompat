import Foundation

public struct DiscoveredNode: Sendable {
    public var mac: MACAddress
    public var nodeType: UInt16
    public var firmware: UInt8
    public var shortName: String
    public var ip: IPv4Address
    public var ode: ODEDevice?
}

/// High-level operations mirroring NMU's ODE workflow.
public final class ODEManager {
    public let socket: ESPSocket

    public init(interfaceName: String? = nil) throws {
        socket = try ESPSocket(interfaceName: interfaceName)
    }

    /// Broadcast ESPP and collect replies. NMU uses reply type 1.
    public func discover(timeout: TimeInterval = 2.0, replyType: UInt8 = 0x01) throws -> [DiscoveredNode] {
        try socket.broadcast(PacketCodec.poll(replyType: replyType))
        var found: [MACAddress: DiscoveredNode] = [:]
        socket.receive(for: timeout) { data, ip in
            guard let g = PacketCodec.parseGenericPollReply(data) else { return }
            let ode = PacketCodec.parseODEPollReply(data, sourceIP: ip)
            found[g.mac] = DiscoveredNode(mac: g.mac, nodeType: g.nodeType, firmware: g.firmware,
                                          shortName: g.shortName, ip: ip, ode: ode)
        }
        return found.values.sorted { $0.mac.description < $1.mac.description }
    }

    public func findODE(_ mac: MACAddress, timeout: TimeInterval = 2.0) throws -> ODEDevice? {
        try discover(timeout: timeout).first { $0.mac == mac }?.ode
    }

    public enum ApplyResult {
        case verified(ODEDevice)
        case mismatch(expected: ODEConfig, actual: ODEDevice)
        case noReply
    }

    /// NMU "Save Config": ESCP, then (only if IP changed) wait 444 ms and ESZZ; then re-poll to verify.
    public func apply(_ newConfig: ODEConfig, to device: ODEDevice,
                      verifyTimeout: TimeInterval = 2.0, rebootWait: TimeInterval = 4.0) throws -> ApplyResult {
        let packet = try PacketCodec.setConfig(mac: device.mac, firmware: device.firmware,
                                               config: newConfig, nodeType: device.nodeType)
        try socket.broadcast(packet)
        let ipChanged = newConfig.ip != device.config.ip
        if ipChanged {
            Thread.sleep(forTimeInterval: 0.444)
            try socket.broadcast(PacketCodec.reset(mac: device.mac))
            Thread.sleep(forTimeInterval: rebootWait)
        } else {
            Thread.sleep(forTimeInterval: 0.3)
        }
        guard let after = try findODE(device.mac, timeout: verifyTimeout) else { return .noReply }
        var expected = newConfig
        if !device.usesExtendedConfig {
            expected.refreshCode = after.config.refreshCode
            expected.optionB = after.config.optionB
            expected.optionC = after.config.optionC
        }
        return after.config == expected ? .verified(after) : .mismatch(expected: expected, actual: after)
    }

    public func reset(_ mac: MACAddress) throws {
        try socket.broadcast(PacketCodec.reset(mac: mac))
    }

    public func factoryReset(_ mac: MACAddress) throws {
        try socket.broadcast(PacketCodec.factoryConfig(mac: mac))
        Thread.sleep(forTimeInterval: 0.444)
        try socket.broadcast(PacketCodec.reset(mac: mac))
    }
}
