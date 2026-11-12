import AppKit
import ESPKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            DeviceList()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                Group {
                    if model.selectedDevice != nil, model.draft != nil {
                        DeviceEditor()
                    } else {
                        EmptyState()
                    }
                }
                .frame(maxHeight: .infinity)
                Divider()
                LogView()
                    .frame(height: 110)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("Interface", selection: $model.selectedInterfaceKey) {
                    Text("All interfaces").tag(Optional<String>.none)
                    Divider()
                    ForEach(model.interfaces, id: \.description) { i in
                        Text("\(i.name) — \(i.address.description)").tag(Optional(AppModel.key(i)))
                    }
                }
                .frame(minWidth: 220)
                .help("Network interface the ODEs are connected to")
                Button {
                    model.refreshInterfaces()
                } label: {
                    Label("Refresh interfaces", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Reload network interfaces")
                Button {
                    Task { await model.discover() }
                } label: {
                    Label("Discover", systemImage: "dot.radiowaves.left.and.right")
                }
                .keyboardShortcut("r")
                .disabled(model.busy)
                .help("Poll for ODEs (⌘R)")
                if model.busy { ProgressView().controlSize(.small) }
            }
        }
        .task {
            await model.discover()
            // The first poll after launch is often lost (local-network privacy / interface warm-up).
            if model.devices.isEmpty {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await model.discover()
            }
        }
    }
}

struct EmptyState: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "network").font(.system(size: 40)).foregroundStyle(.secondary)
            Text(model.devices.isEmpty ? "No ODE found" : "Select an ODE").font(.title3)
            if model.devices.isEmpty {
                Text("Pick the interface the ODEs are on, then press Discover.\nNodes are found by broadcast, so their IP subnet does not matter.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DeviceList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            Section("ODE (\(model.devices.count))") {
                ForEach(model.devices, id: \.mac) { d in
                    DeviceRow(device: d).tag(Optional(d.mac))
                }
            }
            if !model.others.isEmpty {
                Section("Other ESP nodes") {
                    ForEach(model.others, id: \.mac) { n in
                        VStack(alignment: .leading) {
                            Text(n.shortName.isEmpty ? n.mac.description : n.shortName)
                            Text("\(n.ip.description) · type 0x\(String(format: "%04X", n.nodeType))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .selectionDisabled()
                    }
                }
            }
        }
    }
}

extension View {
    @ViewBuilder func selectionDisabled() -> some View {
        if #available(macOS 14.0, *) { self.selectionDisabled(true) } else { self }
    }
}

struct DeviceRow: View {
    @EnvironmentObject var model: AppModel
    let device: ODEDevice

    var body: some View {
        let c = device.config
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(c.name.isEmpty ? "(no name)" : c.name).fontWeight(.medium)
                if model.isOffSubnet(device) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Not in the selected interface's subnet")
                }
            }
            Text(c.ip.description).font(.callout.monospacedDigit())
            Text("\(c.dmxProtocol?.label ?? "?") \(universeText(c)) · \(c.direction?.label ?? "?")")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

func universeText(_ c: ODEConfig) -> String {
    c.dmxProtocol == .artnet ? "\(c.artnetSubnet).\(c.artnetUniverse)" : "U\(c.universe)"
}

struct DeviceEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmIPChange = false
    @State private var confirmFactory = false
    @State private var showPacket = false

    var body: some View {
        let device = model.selectedDevice!
        let draft = Binding(get: { model.draft! }, set: { model.draft = $0 })
        let packet = model.previewPacket()

        Form {
            Section {
                LabeledContent("MAC", value: device.mac.description)
                LabeledContent("Firmware", value: String(format: "0x%02X", device.firmware))
                LabeledContent("Current IP", value: device.config.ip.description)
                LabeledContent("Found on", value: model.deviceInterface[device.mac] ?? "—")
                if model.isOffSubnet(device) {
                    Label("This IP is outside \(model.deviceInterface[device.mac] ?? "the interface")'s subnet. ESP config still works, but Art-Net senders on this Mac won't reach it.",
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Device")
            }

            Section("Settings") {
                TextField("Name", text: draft.name)
                    .help("ASCII, up to 19 characters")
                TextField("IP address", text: draft.ip)
                    .font(.body.monospacedDigit())
                Picker("Protocol", selection: draft.dmxProtocol) {
                    ForEach(DMXProtocol.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Port direction", selection: draft.direction) {
                    ForEach(PortDirection.allCases, id: \.self) { Text($0.label.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                if draft.wrappedValue.dmxProtocol == .artnet {
                    Picker("Art-Net subnet", selection: draft.artnetSubnet) {
                        ForEach(0..<16, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Picker("Art-Net universe", selection: draft.artnetUniverse) {
                        ForEach(0..<16, id: \.self) { Text("\($0)").tag($0) }
                    }
                    Stepper(value: draft.universe, in: 0...255) {
                        HStack {
                            Text("Port-Address")
                            Spacer()
                            TextField("", value: draft.universe, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Text("Art-Net \(0):\(draft.wrappedValue.artnetSubnet):\(draft.wrappedValue.artnetUniverse) (Net:Sub-Net:Universe). ODE Mk1 stores one byte, so Net is fixed at 0 and the reachable range is Port-Address 0–255.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Stepper(value: draft.universe, in: 0...255) {
                        HStack {
                            Text("ESP universe")
                            Spacer()
                            TextField("", value: draft.universe, format: .number)
                                .frame(width: 60)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
                if device.usesExtendedConfig {
                    Picker("Refresh rate", selection: draft.refreshHz) {
                        Text("Keep current (code \(device.config.refreshCode))").tag(Optional<Int>.none)
                        ForEach([44, 40, 35, 30, 25, 20], id: \.self) { Text("\($0) Hz").tag(Optional($0)) }
                    }
                }
            }

            Section {
                DisclosureGroup("ESCP packet preview", isExpanded: $showPacket) {
                    if let bytes = packet.bytes {
                        Text(hexDump(bytes))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let err = packet.error {
                    Label(err, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Menu("More") {
                        Button("Send Reset (ESZZ)") { Task { await model.resetSelected() } }
                        Divider()
                        Button("Factory Reset…", role: .destructive) { confirmFactory = true }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Revert") { model.select(model.selection) }
                        .disabled(!model.hasChanges || model.busy)
                    Button("Apply") {
                        if model.draftChangesIP { confirmIPChange = true } else { Task { await model.applyDraft() } }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.hasChanges || packet.bytes == nil || model.busy)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Change IP address?", isPresented: $confirmIPChange) {
            Button("Change IP and restart ODE") { Task { await model.applyDraft() } }
        } message: {
            Text("The ODE will restart with \(model.draft?.ip ?? ""). Make sure that address is free on the network.\n\nODE Mk1 keeps answering ARP/ping on its old address until it is power-cycled, so power-cycle it before reusing the old address.")
        }
        .confirmationDialog("Factory reset this ODE?", isPresented: $confirmFactory) {
            Button("Factory Reset", role: .destructive) { Task { await model.factoryResetSelected() } }
        } message: {
            Text("Sets IP to 10.\(device.mac.bytes[3]).\(device.mac.bytes[4]).\(device.mac.bytes[5]), name \"ODE Factory\", Art-Net 0.0, output, then restarts.")
        }
    }
}

func hexDump(_ b: [UInt8]) -> String {
    stride(from: 0, to: b.count, by: 16).map { off in
        String(format: "%04x  ", off) + b[off..<min(off + 16, b.count)].map { String(format: "%02x", $0) }.joined(separator: " ")
    }.joined(separator: "\n")
}

struct LogView: View {
    @EnvironmentObject var model: AppModel
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        ScrollViewReader { proxy in
            List(model.log) { e in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.time.string(from: e.date)).foregroundStyle(.secondary)
                    Text(e.text).foregroundStyle(color(e.level)).textSelection(.enabled)
                }
                .font(.system(.caption, design: .monospaced))
                .id(e.id)
            }
            .onChange(of: model.log.count) { _ in
                if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func color(_ l: LogEntry.Level) -> Color {
        switch l {
        case .info: return .primary
        case .success: return .green
        case .error: return .red
        }
    }
}
