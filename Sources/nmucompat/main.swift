import ESPKit
import Foundation

let usage = """
nmucompat — ENTTEC ODE Mk1 configuration over ESP (NMU-compatible)

USAGE
  nmucompat interfaces
  nmucompat discover [-i IF] [-t SEC] [--raw]   (all interfaces when -i is omitted)
  nmucompat show MAC [-i IF]
  nmucompat set MAC [-i IF] [--ip A.B.C.D] [--name NAME]
                    [--protocol esp|artnet] [--direction output|input|disabled]
                    [--universe 0-255] [--artnet SUBNET.UNIVERSE] [--refresh HZ]
                    [--dry-run]
  nmucompat reset MAC [-i IF]
  nmucompat factory MAC [-i IF] --yes

NOTES
  -i IF   Pin traffic to an interface (e.g. en0). Recommended: without it,
          255.255.255.255 only goes out the default-route interface.
  Nodes are addressed by MAC, so the Mac does not need to be on the node's subnet.
  UDP port 3333 must be free (quit any running ESP/NMU-like app).
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}

struct Args {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []

    static let valueOptions: Set<String> = ["-i", "-t", "--ip", "--name", "--protocol", "--direction",
                                            "--universe", "--artnet", "--refresh"]

    init(_ argv: [String]) throws {
        var it = argv.makeIterator()
        while let a = it.next() {
            if Args.valueOptions.contains(a) {
                guard let v = it.next() else { throw CLIError("missing value for \(a)") }
                options[a] = v
            } else if a.hasPrefix("-") {
                flags.insert(a)
            } else {
                positional.append(a)
            }
        }
    }

    func mac(at i: Int) throws -> MACAddress {
        guard positional.count > i else { throw CLIError("MAC address required") }
        guard let m = MACAddress(string: positional[i]) else { throw CLIError("invalid MAC: \(positional[i])") }
        return m
    }

    var timeout: TimeInterval { options["-t"].flatMap(TimeInterval.init) ?? 2.0 }
}

func describe(_ d: ODEDevice) -> String {
    let c = d.config
    var lines = [
        "MAC        \(d.mac)",
        "IP         \(c.ip)",
        "Name       \(c.name)",
        "Firmware   0x\(String(format: "%02X", d.firmware))  (sub-type \(d.subType))",
        "Protocol   \(c.dmxProtocol?.label ?? "unknown(\(c.protocolRaw))")",
        "Direction  \(c.direction?.label ?? "unknown(\(c.directionRaw))")",
    ]
    if c.dmxProtocol == .artnet {
        lines.append("Universe   \(c.universe)  (Art-Net subnet \(c.artnetSubnet), universe \(c.artnetUniverse))")
    } else {
        lines.append("Universe   \(c.universe)")
    }
    if d.usesExtendedConfig {
        lines.append("Extended   refresh=\(c.refreshCode) optB=\(c.optionB) optC=\(c.optionC)")
    }
    return lines.joined(separator: "\n")
}

func hex(_ b: [UInt8]) -> String {
    stride(from: 0, to: b.count, by: 16).map { off in
        let row = b[off..<min(off + 16, b.count)]
        return String(format: "%04x  ", off) + row.map { String(format: "%02x", $0) }.joined(separator: " ")
    }.joined(separator: "\n")
}

func requireODE(_ m: ODEManager, _ mac: MACAddress, _ t: TimeInterval) throws -> ODEDevice {
    guard let d = try m.findODE(mac, timeout: t) else {
        throw CLIError("no ODE with MAC \(mac) answered (check -i and cabling; run `discover`)")
    }
    return d
}

func run() throws {
    let argv = Array(CommandLine.arguments.dropFirst())
    guard let cmd = argv.first, !["-h", "--help", "help"].contains(cmd) else {
        print(usage); return
    }
    let args = try Args(Array(argv.dropFirst()))

    switch cmd {
    case "interfaces":
        NetworkInterface.all().forEach { print($0) }

    case "discover":
        let scanner = try MultiInterfaceScanner(interfaceNames: args.options["-i"].map { [$0] })
        let hits = scanner.discover(timeout: args.timeout)
        if hits.isEmpty { print("no ESP nodes answered"); return }
        for h in hits {
            let n = h.node
            print("Interface  \(h.interfaceName)")
            if let d = n.ode {
                print(describe(d))
            } else {
                print("MAC        \(n.mac)\nIP         \(n.ip)\nNodeType   0x\(String(format: "%04X", n.nodeType)) (not an ODE)\nShortName  \(n.shortName)")
            }
            if args.flags.contains("--raw"), let raw = n.ode?.raw { print(hex(raw)) }
            print("")
        }

    case "show":
        let m = try ODEManager(interfaceName: args.options["-i"])
        let d = try requireODE(m, try args.mac(at: 0), args.timeout)
        print(describe(d))
        print(hex(d.raw))

    case "set":
        let mac = try args.mac(at: 0)
        let m = try ODEManager(interfaceName: args.options["-i"])
        let d = try requireODE(m, mac, args.timeout)
        var c = d.config
        if let s = args.options["--ip"] {
            guard let ip = IPv4Address(string: s) else { throw CLIError("invalid IP: \(s)") }
            c.ip = ip
        }
        if let s = args.options["--name"] { c.name = s }
        if let s = args.options["--protocol"]?.lowercased() {
            switch s {
            case "esp": c.protocolRaw = DMXProtocol.esp.rawValue
            case "artnet", "art-net": c.protocolRaw = DMXProtocol.artnet.rawValue
            default: throw CLIError("protocol must be esp or artnet")
            }
        }
        if let s = args.options["--direction"]?.lowercased() {
            guard let dir = PortDirection.allCases.first(where: { $0.label == s }) else {
                throw CLIError("direction must be output, input or disabled")
            }
            c.directionRaw = dir.rawValue
        }
        if let s = args.options["--universe"] {
            guard let u = UInt8(s) else { throw CLIError("universe must be 0-255") }
            c.universe = u
        }
        if let s = args.options["--artnet"] {
            let p = s.split(separator: ".")
            guard p.count == 2, let sn = UInt8(p[0]), let un = UInt8(p[1]), sn < 16, un < 16 else {
                throw CLIError("--artnet expects SUBNET.UNIVERSE, each 0-15")
            }
            c.universe = sn << 4 | un
        }
        if let s = args.options["--refresh"] {
            guard d.usesExtendedConfig else { throw CLIError("refresh rate needs firmware >= 0x18") }
            guard let hz = Int(s), hz > 0 else { throw CLIError("invalid refresh rate") }
            c.refreshCode = ODEConfig.refreshCode(hz: hz)
        }

        let packet = try PacketCodec.setConfig(mac: d.mac, firmware: d.firmware, config: c, nodeType: d.nodeType)
        print("Current:\n\(describe(d))\n")
        var after = d; after.config = c
        print("New:\n\(describe(after))\n")
        print("ESCP packet (\(packet.count) bytes):\n\(hex(packet))")
        if c.ip != d.config.ip { print("IP change → ESZZ reset will follow") }
        if args.flags.contains("--dry-run") { print("\n--dry-run: nothing sent"); return }
        if c == d.config { print("\nnothing to change"); return }

        switch try m.apply(c, to: d) {
        case .verified(let v): print("\nOK — verified:\n\(describe(v))")
        case .noReply: throw CLIError("sent, but node did not answer the verification poll")
        case .mismatch(_, let a): throw CLIError("sent, but node reports a different config:\n\(describe(a))\n\(hex(a.raw))")
        }

    case "reset":
        let m = try ODEManager(interfaceName: args.options["-i"])
        try m.reset(try args.mac(at: 0))
        print("ESZZ sent")

    case "factory":
        let mac = try args.mac(at: 0)
        guard args.flags.contains("--yes") else {
            throw CLIError("factory resets IP to 10.\(mac.bytes[3]).\(mac.bytes[4]).\(mac.bytes[5]), name, Art-Net 0, output. Re-run with --yes")
        }
        let m = try ODEManager(interfaceName: args.options["-i"])
        try m.factoryReset(mac)
        print("factory config + ESZZ sent")

    default:
        throw CLIError("unknown command \(cmd)\n\n\(usage)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
