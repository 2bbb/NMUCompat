@testable import ESPKit
import XCTest

final class PacketTests: XCTestCase {
    let mac = MACAddress([0x00, 0x50, 0xC2, 0x12, 0x34, 0x56])

    func testPoll() {
        XCTAssertEqual(PacketCodec.poll(), [0x45, 0x53, 0x50, 0x50, 0x01])
    }

    func testReset() {
        XCTAssertEqual(PacketCodec.reset(mac: mac), Array("ESZZ".utf8) + mac.bytes)
    }

    func testSetConfigShortLayout() throws {
        let cfg = ODEConfig(ip: IPv4Address([192, 168, 1, 50]), name: "Truss 1",
                            directionRaw: 1, protocolRaw: 0, universe: 7)
        let p = try PacketCodec.setConfig(mac: mac, firmware: 0x10, config: cfg)
        XCTAssertEqual(p.count, 42)
        XCTAssertEqual(Array(p[0..<4]), Array("ESCP".utf8))
        XCTAssertEqual(Array(p[4..<6]), [0x00, 0x0B])
        XCTAssertEqual(Array(p[6..<10]), [192, 168, 1, 50])
        XCTAssertEqual(Array(p[10..<16]), mac.bytes)
        XCTAssertEqual(Array(p[16..<18]), [0x00, 0x18])
        XCTAssertEqual(p[18], 0x01)
        XCTAssertEqual(Array(p[19..<26]), Array("Truss 1".utf8))
        XCTAssertEqual(p[26], 0)
        XCTAssertEqual(Array(p[39..<42]), [1, 0, 7])
    }

    func testSetConfigExtendedLayout() throws {
        let cfg = ODEConfig(ip: IPv4Address([10, 0, 0, 2]), name: "A", directionRaw: 2, protocolRaw: 1,
                            universe: 0x21, refreshCode: 9, optionB: 1, optionC: 2)
        let p = try PacketCodec.setConfig(mac: mac, firmware: 0x18, config: cfg)
        XCTAssertEqual(p.count, 45)
        XCTAssertEqual(Array(p[16..<18]), [0x00, 0x1B])
        XCTAssertEqual(p[18], 0x05)
        XCTAssertEqual(Array(p[39..<45]), [2, 1, 0x21, 9, 1, 2])
    }

    func testNameLimits() {
        let cfg = ODEConfig(ip: IPv4Address([1, 2, 3, 4]), name: String(repeating: "x", count: 20),
                            directionRaw: 1, protocolRaw: 1, universe: 0)
        XCTAssertThrowsError(try PacketCodec.setConfig(mac: mac, firmware: 0, config: cfg))
    }

    func testFactoryMatchesNMULayout() {
        let p = PacketCodec.factoryConfig(mac: mac)
        XCTAssertEqual(p.count, 42)
        XCTAssertEqual(Array(p[6..<10]), [10, 0x12, 0x34, 0x56])
        XCTAssertEqual(Array(p[19..<30]), Array("ODE Factory".utf8))
        XCTAssertEqual(Array(p[39..<42]), [1, 1, 0])
    }

    func testParsePollReplyRoundTrip() throws {
        var r = [UInt8](repeating: 0, count: 86)
        r.replaceSubrange(0..<4, with: Array("ESPR".utf8))
        r.replaceSubrange(4..<10, with: mac.bytes)
        r[10] = 0x00; r[11] = 0x0B; r[12] = 0x18; r[13] = 1
        r.replaceSubrange(14..<17, with: Array("ODE".utf8))
        r.replaceSubrange(27..<34, with: Array("Stage L".utf8))
        r[47] = 1; r[48] = 1; r[49] = 0x13
        r[83] = 9; r[84] = 0; r[85] = 1
        let d = try XCTUnwrap(PacketCodec.parseODEPollReply(r, sourceIP: IPv4Address([10, 18, 52, 86])))
        XCTAssertEqual(d.mac, mac)
        XCTAssertEqual(d.config.name, "Stage L")
        XCTAssertEqual(d.config.direction, .output)
        XCTAssertEqual(d.config.dmxProtocol, .artnet)
        XCTAssertEqual(d.config.artnetSubnet, 1)
        XCTAssertEqual(d.config.artnetUniverse, 3)
        XCTAssertEqual(d.config.refreshCode, 9)
        XCTAssertTrue(d.usesExtendedConfig)
    }

    func testRejectsOtherNodeTypes() {
        var r = [UInt8](repeating: 0, count: 60)
        r.replaceSubrange(0..<4, with: Array("ESPR".utf8))
        r[11] = 0x04
        XCTAssertNil(PacketCodec.parseODEPollReply(r, sourceIP: IPv4Address([1, 1, 1, 1])))
    }

    func testMACParsing() {
        XCTAssertEqual(MACAddress(string: "00:50:c2:12:34:56"), mac)
        XCTAssertEqual(MACAddress(string: "0050C2123456"), mac)
        XCTAssertNil(MACAddress(string: "00:50:c2:12:34"))
    }

    func testRefreshCode() {
        // 40 Hz → (25-23)/2.052+0.5 → 1
        XCTAssertEqual(ODEConfig.refreshCode(hz: 40), 1)
        // 20 Hz → (50-23)/2.052+0.5 → 13
        XCTAssertEqual(ODEConfig.refreshCode(hz: 20), 13)
    }
}
