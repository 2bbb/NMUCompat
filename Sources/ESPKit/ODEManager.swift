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
    ///
    /// Observed on ODE Mk1 fw 0x16: the node restarts by itself after any accepted ESCP and is
    /// silent for ~1-2 s, so verification polls repeatedly until `verifyTimeout` runs out.
    public func apply(_ newConfig: ODEConfig, to device: ODEDevice,
                      verifyTimeout: TimeInterval = 8.0) throws -> ApplyResult {
        let packet = try PacketCodec.setConfig(mac: device.mac, firmware: device.firmware,
                                               config: newConfig, nodeType: device.nodeType)
        try socket.broadcastCommand(packet)
        if newConfig.ip != device.config.ip {
            Thread.sleep(forTimeInterval: 0.444)
            try socket.broadcastCommand(PacketCodec.reset(mac: device.mac))
        }
        Thread.sleep(forTimeInterval: 1.0)

        var expected = newConfig
        var last: ODEDevice?
        let deadline = Date().addingTimeInterval(verifyTimeout)
        while Date() < deadline {
            if let after = try findODE(device.mac, timeout: 1.0) {
                if !device.usesExtendedConfig {
                    expected.refreshCode = after.config.refreshCode
                    expected.optionB = after.config.optionB
                    expected.optionC = after.config.optionC
                }
                if after.config == expected { return .verified(after) }
                last = after
            }
        }
        if let last { return .mismatch(expected: expected, actual: last) }
        return .noReply
    }

    public func reset(_ mac: MACAddress) throws {
        try socket.broadcastCommand(PacketCodec.reset(mac: mac))
    }

    public func factoryReset(_ mac: MACAddress) throws {
        try socket.broadcastCommand(PacketCodec.factoryConfig(mac: mac))
        Thread.sleep(forTimeInterval: 0.444)
        try socket.broadcastCommand(PacketCodec.reset(mac: mac))
    }
}
