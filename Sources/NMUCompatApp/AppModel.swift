import ESPKit
import Foundation
import SwiftUI

struct LogEntry: Identifiable {
    enum Level { case info, success, error }
    let id = UUID()
    let date = Date()
    let level: Level
    let text: String
}

/// Editable copy of an ODE's settings, expressed in UI terms.
struct ODEDraft: Equatable {
    var name: String
    var ip: String
    var dmxProtocol: DMXProtocol
    var direction: PortDirection
    /// ESP universe (0-255) or Art-Net combined byte.
    var universe: Int
    var refreshHz: Int?

    init(_ c: ODEConfig) {
        name = c.name
        ip = c.ip.description
        dmxProtocol = c.dmxProtocol ?? .artnet
        direction = c.direction ?? .output
        universe = Int(c.universe)
        refreshHz = nil
    }

    var artnetSubnet: Int {
        get { universe >> 4 }
        set { universe = (newValue & 0x0F) << 4 | (universe & 0x0F) }
    }

    var artnetUniverse: Int {
        get { universe & 0x0F }
        set { universe = (universe & 0xF0) | (newValue & 0x0F) }
    }

    enum ValidationError: LocalizedError {
        case ip, name
        var errorDescription: String? {
            switch self {
            case .ip: return "IP address is not a valid IPv4 address."
            case .name: return "Name must be ASCII and at most 19 characters."
            }
        }
    }

    func apply(to base: ODEConfig) throws -> ODEConfig {
        guard let ipAddr = IPv4Address(string: ip.trimmingCharacters(in: .whitespaces)) else {
            throw ValidationError.ip
        }
        guard name.allSatisfy(\.isASCII), name.utf8.count < ESP.nameLength else { throw ValidationError.name }
        var c = base
        c.ip = ipAddr
        c.name = name
        c.protocolRaw = dmxProtocol.rawValue
        c.directionRaw = direction.rawValue
        c.universe = UInt8(clamping: universe)
        if let hz = refreshHz { c.refreshCode = ODEConfig.refreshCode(hz: hz) }
        return c
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var interfaces: [NetworkInterface] = []
    /// Keyed by "name address" because one NIC can carry several IPv4 addresses.
    @Published var selectedInterfaceKey: String? {
        didSet { UserDefaults.standard.set(selectedInterfaceKey, forKey: "interface") }
    }
    @Published var devices: [ODEDevice] = []
    /// Interface each ODE answered on, so writes go out the same NIC.
    @Published var deviceInterface: [MACAddress: String] = [:]
    @Published var others: [DiscoveredNode] = []
    @Published var selection: MACAddress?
    @Published var draft: ODEDraft?
    @Published var busy = false
    @Published var log: [LogEntry] = []

    init() {
        refreshInterfaces()
        // nil = scan all interfaces (default).
        selectedInterfaceKey = UserDefaults.standard.string(forKey: "interface")
        if selectedInterfaceKey != nil, selectedInterface == nil { selectedInterfaceKey = nil }
    }

    static func key(_ i: NetworkInterface) -> String { "\(i.name) \(i.address)" }

    var selectedInterface: NetworkInterface? {
        interfaces.first { Self.key($0) == selectedInterfaceKey }
    }

    var selectedDevice: ODEDevice? {
        devices.first { $0.mac == selection }
    }

    func refreshInterfaces() {
        interfaces = NetworkInterface.all()
    }

    func select(_ mac: MACAddress?) {
        selection = mac
        draft = selectedDevice.map { ODEDraft($0.config) }
    }

    func append(_ level: LogEntry.Level, _ text: String) {
        log.append(LogEntry(level: level, text: text))
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }

    // MARK: - Network operations (run off the main actor)

    /// Interface to use for a write to `mac`: the one it was discovered on, else the selected one.
    func interfaceName(for mac: MACAddress) -> String? {
        deviceInterface[mac] ?? selectedInterface?.name
    }

    private func run<T>(_ label: String, interface ifName: String?,
                        _ work: @escaping (ODEManager) throws -> T) async -> T? {
        busy = true
        defer { busy = false }
        do {
            return try await Task.detached(priority: .userInitiated) {
                let m = try ODEManager(interfaceName: ifName)
                return try work(m)
            }.value
        } catch {
            append(.error, "\(label): \(error)")
            return nil
        }
    }

    func discover() async {
        let names: [String]
        if let i = selectedInterface {
            names = [i.name]
        } else {
            refreshInterfaces()
            var seen = Set<String>()
            names = interfaces.map(\.name).filter { seen.insert($0).inserted }
        }
        busy = true
        defer { busy = false }
        let explicit = selectedInterface != nil
        let outcome: Result<(hits: [MultiInterfaceScanner.Hit], failures: [String: Error]), Error> =
            await Task.detached(priority: .userInitiated) {
                Result {
                    let scanner = try MultiInterfaceScanner(interfaceNames: names)
                    let hits = scanner.discover(timeout: 1.5)
                    return (hits, scanner.failures)
                }
            }.value

        var odes: [MACAddress: ODEDevice] = [:]
        var otherNodes: [MACAddress: DiscoveredNode] = [:]
        var where_: [MACAddress: String] = [:]
        switch outcome {
        case .failure(let e):
            append(.error, "Discover: \(e)")
            return
        case .success(let r):
            for h in r.hits {
                if let o = h.node.ode { odes[o.mac] = o; where_[o.mac] = h.interfaceName } else { otherNodes[h.node.mac] = h.node }
            }
            // Scanning every NIC hits tunnels/virtual NICs that can't broadcast; only report when explicit.
            if explicit { r.failures.forEach { append(.error, "Discover on \($0.key): \($0.value)") } }
        }
        devices = odes.values.sorted { ($0.config.name, $0.mac.description) < ($1.config.name, $1.mac.description) }
        others = otherNodes.values.sorted { $0.mac.description < $1.mac.description }
        deviceInterface = where_
        let scope = selectedInterface.map { $0.name } ?? "all interfaces"
        append(.info, "Discover on \(scope): \(devices.count) ODE, \(others.count) other ESP node(s)")
        if let sel = selection, devices.contains(where: { $0.mac == sel }) {
            select(sel)
        } else {
            select(devices.first?.mac)
        }
    }

    func previewPacket() -> (bytes: [UInt8]?, error: String?) {
        guard let d = selectedDevice, let draft else { return (nil, nil) }
        do {
            let c = try draft.apply(to: d.config)
            return (try PacketCodec.setConfig(mac: d.mac, firmware: d.firmware, config: c, nodeType: d.nodeType), nil)
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    var draftChangesIP: Bool {
        guard let d = selectedDevice, let draft else { return false }
        return draft.ip.trimmingCharacters(in: .whitespaces) != d.config.ip.description
    }

    var hasChanges: Bool {
        guard let d = selectedDevice, let draft else { return false }
        return draft != ODEDraft(d.config)
    }

    func applyDraft() async {
        guard let device = selectedDevice, let draft else { return }
        let config: ODEConfig
        do { config = try draft.apply(to: device.config) } catch {
            append(.error, error.localizedDescription); return
        }
        append(.info, "Sending ESCP to \(device.mac)\(config.ip != device.config.ip ? " + ESZZ (IP change)" : "")")
        guard let result = await run("Apply", interface: interfaceName(for: device.mac),
                                     { try $0.apply(config, to: device) }) else { return }
        switch result {
        case .verified(let after):
            replace(after)
            append(.success, "\(after.mac): configuration verified")
        case .mismatch(_, let actual):
            replace(actual)
            append(.error, "\(actual.mac): node reports different settings after write")
        case .noReply:
            append(.error, "\(device.mac): no reply after write — run Discover (IP may have changed)")
        }
    }

    func resetSelected() async {
        guard let mac = selection else { return }
        if await run("Reset", interface: interfaceName(for: mac), { try $0.reset(mac) }) != nil {
            append(.info, "ESZZ sent to \(mac)")
        }
    }

    func factoryResetSelected() async {
        guard let mac = selection else { return }
        if await run("Factory", interface: interfaceName(for: mac), { try $0.factoryReset(mac) }) != nil {
            append(.info, "Factory config + ESZZ sent to \(mac)")
        }
    }

    private func replace(_ d: ODEDevice) {
        if let i = devices.firstIndex(where: { $0.mac == d.mac }) { devices[i] = d } else { devices.append(d) }
        select(d.mac)
    }

    /// True when the node is not reachable by IP from the selected interface (Art-Net senders would miss it).
    func isOffSubnet(_ d: ODEDevice) -> Bool {
        guard let name = deviceInterface[d.mac] ?? selectedInterface?.name else { return false }
        // A NIC can carry several addresses; the node is reachable if any of them shares its subnet.
        let addrs = interfaces.filter { $0.name == name }
        guard !addrs.isEmpty else { return false }
        return !addrs.contains { i in !zip(zip(i.address.bytes, i.netmask.bytes), d.config.ip.bytes).contains { pair, ip in
            (pair.0 & pair.1) != (ip & pair.1)
        } }
    }
}
