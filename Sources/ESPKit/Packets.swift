import Foundation

/// ESP (ENTTEC Show Protocol) packet definitions for ODE Mk1 configuration.
/// See docs/PROTOCOL.md for the byte layouts and their provenance.
public enum ESP {
    public static let port: UInt16 = 3333
    public static let odeNodeType: UInt16 = 0x000B
    /// Firmware version from which the extended (45 byte) ESCP layout is used.
    public static let extendedConfigFirmware: UInt8 = 0x18
    public static let nameLength = 20
}

public struct MACAddress: Hashable, CustomStringConvertible, Sendable {
    public var bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        precondition(bytes.count == 6)
        self.bytes = bytes
    }

    /// Accepts `00:50:C2:12:34:56`, `00-50-c2-12-34-56` or `0050C2123456`.
    public init?(string: String) {
        let hex = string.filter { $0.isHexDigit }
        guard hex.count == 12, string.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "-" }) else { return nil }
        var out: [UInt8] = []
        var idx = hex.startIndex
        for _ in 0..<6 {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        self.bytes = out
    }

    public var description: String { bytes.map { String(format: "%02X", $0) }.joined(separator: ":") }
}

public struct IPv4Address: Hashable, CustomStringConvertible, Sendable {
    public var bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        precondition(bytes.count == 4)
        self.bytes = bytes
    }

    public init?(string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard let v = UInt8(p) else { return nil }
            out.append(v)
        }
        self.bytes = out
    }

    public var description: String { bytes.map(String.init).joined(separator: ".") }
}

public enum PortDirection: UInt8, CaseIterable, Sendable {
    case disabled = 0, output = 1, input = 2

    public var label: String {
        switch self {
        case .disabled: return "disabled"
        case .output: return "output"
        case .input: return "input"
        }
    }
}

public enum DMXProtocol: UInt8, CaseIterable, Sendable {
    case esp = 0, artnet = 1

    public var label: String { self == .esp ? "ESP" : "Art-Net" }
}

/// Configurable state of an ODE, as carried in ESPR (poll reply) and ESCP (set config).
public struct ODEConfig: Equatable, Sendable {
    public var ip: IPv4Address
    public var name: String
    /// Raw values are kept so that unknown codes round-trip unchanged.
    public var directionRaw: UInt8
    public var protocolRaw: UInt8
    /// Art-Net: `(subnet << 4) | universe`. ESP: 0-255.
    public var universe: UInt8
    /// Only present on firmware >= 0x18.
    public var refreshCode: UInt8
    public var optionB: UInt8
    public var optionC: UInt8

    public var direction: PortDirection? { PortDirection(rawValue: directionRaw) }
    public var dmxProtocol: DMXProtocol? { DMXProtocol(rawValue: protocolRaw) }
    public var artnetSubnet: UInt8 { universe >> 4 }
    public var artnetUniverse: UInt8 { universe & 0x0F }

    public init(ip: IPv4Address, name: String, directionRaw: UInt8, protocolRaw: UInt8, universe: UInt8,
                refreshCode: UInt8 = 0, optionB: UInt8 = 0, optionC: UInt8 = 0) {
        self.ip = ip
        self.name = name
        self.directionRaw = directionRaw
        self.protocolRaw = protocolRaw
        self.universe = universe
        self.refreshCode = refreshCode
        self.optionB = optionB
        self.optionC = optionC
    }

    /// NMU's conversion (Config_Dialog::UpdateDevice).
    public static func refreshCode(hz: Int) -> UInt8 {
        let h = max(hz, 2)
        let v = (Double(1000 / h - 23) / 2.052 + 0.5).rounded(.down)
        return UInt8(truncatingIfNeeded: Int(v))
    }
}

public struct ODEDevice: Sendable {
    public var mac: MACAddress
    public var nodeType: UInt16
    public var firmware: UInt8
    public var subType: UInt8
    public var shortName: String
    public var config: ODEConfig
    /// The full reply, kept for diagnostics.
    public var raw: [UInt8]

    public var usesExtendedConfig: Bool { firmware >= ESP.extendedConfigFirmware }
}

public enum PacketError: Error, CustomStringConvertible {
    case nameTooLong(Int)
    case nonASCIIName

    public var description: String {
        switch self {
        case .nameTooLong(let n): return "device name is \(n) bytes; max is \(ESP.nameLength - 1)"
        case .nonASCIIName: return "device name must be ASCII"
        }
    }
}

public enum PacketCodec {
    public static func poll(replyType: UInt8 = 0x01) -> [UInt8] {
        Array("ESPP".utf8) + [replyType]
    }

    public static func reset(mac: MACAddress) -> [UInt8] {
        Array("ESZZ".utf8) + mac.bytes
    }

    /// Builds an ESCP packet exactly as ESPNet::ODE_SendConfig does.
    public static func setConfig(mac: MACAddress, firmware: UInt8, config: ODEConfig,
                                 nodeType: UInt16 = ESP.odeNodeType) throws -> [UInt8] {
        guard config.name.allSatisfy({ $0.isASCII }) else { throw PacketError.nonASCIIName }
        let nameBytes = Array(config.name.utf8)
        guard nameBytes.count < ESP.nameLength else { throw PacketError.nameTooLong(nameBytes.count) }

        let extended = firmware >= ESP.extendedConfigFirmware
        let payloadLength: UInt16 = extended ? 0x1B : 0x18

        var p: [UInt8] = Array("ESCP".utf8)
        p += [UInt8(nodeType >> 8), UInt8(nodeType & 0xFF)]
        p += config.ip.bytes
        p += mac.bytes
        p += [UInt8(payloadLength >> 8), UInt8(payloadLength & 0xFF)]
        p.append(extended ? 0x05 : 0x01)
        p += nameBytes + [UInt8](repeating: 0, count: ESP.nameLength - nameBytes.count)
        p += [config.directionRaw, config.protocolRaw, config.universe]
        if extended {
            p += [config.refreshCode, config.optionB, config.optionC]
        }
        return p
    }

    /// Factory defaults as sent by ESPNet::SendFactoryConfig.
    public static func factoryConfig(mac: MACAddress) -> [UInt8] {
        // NMU parses MAC[3..5] as hex strings; for byte input this is just the byte values.
        let ip = IPv4Address([10, mac.bytes[3], mac.bytes[4], mac.bytes[5]])
        let cfg = ODEConfig(ip: ip, name: "ODE Factory", directionRaw: 1, protocolRaw: 1, universe: 0)
        // Factory packet always uses the short (format 1) layout.
        return try! setConfig(mac: mac, firmware: 0, config: cfg)
    }

    /// Parses an ESPR from an ODE. Returns nil for other packets or other node types.
    public static func parseODEPollReply(_ d: [UInt8], sourceIP: IPv4Address) -> ODEDevice? {
        guard d.count >= 50, Array(d[0..<4]) == Array("ESPR".utf8) else { return nil }
        let nodeType = UInt16(d[10]) << 8 | UInt16(d[11])
        guard nodeType == ESP.odeNodeType else { return nil }
        let firmware = d[12]
        var cfg = ODEConfig(
            ip: sourceIP,
            name: cString(d[27..<47]),
            directionRaw: d[47],
            protocolRaw: d[48],
            universe: d[49]
        )
        if firmware >= ESP.extendedConfigFirmware, d.count >= 86 {
            cfg.refreshCode = d[83]
            cfg.optionB = d[84]
            cfg.optionC = d[85]
        }
        return ODEDevice(
            mac: MACAddress(Array(d[4..<10])),
            nodeType: nodeType,
            firmware: firmware,
            subType: d[13],
            shortName: cString(d[14..<24]),
            config: cfg,
            raw: d
        )
    }

    /// Any ESPR, regardless of node type (for discovery diagnostics).
    public static func parseGenericPollReply(_ d: [UInt8]) -> (mac: MACAddress, nodeType: UInt16, firmware: UInt8, shortName: String)? {
        guard d.count >= 24, Array(d[0..<4]) == Array("ESPR".utf8) else { return nil }
        return (MACAddress(Array(d[4..<10])), UInt16(d[10]) << 8 | UInt16(d[11]), d[12], cString(d[14..<24]))
    }

    static func cString(_ s: ArraySlice<UInt8>) -> String {
        let bytes = s.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
