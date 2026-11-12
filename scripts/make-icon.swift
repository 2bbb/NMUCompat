// Generates Resources/AppIcon.icns: a DMX node (5-pin XLR face) with Ethernet broadcast arcs.
//
//   swift scripts/make-icon.swift      (run from the repository root; needs `iconutil`)
//
// Drawn with Core Graphics so the icon is reproducible and has no external assets.
import AppKit
import CoreGraphics
import Foundation

let iconsetDir = URL(fileURLWithPath: "Resources/AppIcon.iconset")
let icnsPath = "Resources/AppIcon.icns"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Draws the icon on a 1024×1024 canvas (origin bottom-left).
func draw(_ ctx: CGContext) {
    // macOS Big Sur+ grid: 824×824 body centered, corner radius ≈ 185.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x101820))
    ctx.fillPath()
    ctx.restoreGState()

    // Background gradient: deep navy → stage teal.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [color(0x0B1A2E), color(0x0E3B4F), color(0x13707A)] as CFArray,
                        locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 824, y: 924), options: [])

    // Soft spotlight from the top.
    let spot = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(spot, startCenter: CGPoint(x: 512, y: 980), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    ctx.restoreGState()

    // Broadcast arcs (Ethernet / ESP) above the connector.
    let center = CGPoint(x: 512, y: 430)
    ctx.setLineCap(.round)
    for (i, r) in [255.0, 335.0, 415.0].enumerated() {
        ctx.setStrokeColor(color(0x7FE3E0, 0.95 - Double(i) * 0.22))
        ctx.setLineWidth(42)
        ctx.addArc(center: center, radius: r, startAngle: .pi * 0.28, endAngle: .pi * 0.72, clockwise: false)
        ctx.strokePath()
    }

    // XLR connector: metal ring + dark face + 5 pins.
    let ringR: CGFloat = 190
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(0x000000, 0.45))
    ctx.addEllipse(in: CGRect(x: center.x - ringR, y: center.y - ringR, width: ringR * 2, height: ringR * 2))
    ctx.setFillColor(color(0xC9D3DA))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - ringR, y: center.y - ringR, width: ringR * 2, height: ringR * 2))
    ctx.clip()
    let metal = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [color(0xF2F6F8), color(0x9AA6AE)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(metal, start: CGPoint(x: center.x, y: center.y + ringR),
                           end: CGPoint(x: center.x, y: center.y - ringR), options: [])
    ctx.restoreGState()

    let faceR: CGFloat = 150
    ctx.addEllipse(in: CGRect(x: center.x - faceR, y: center.y - faceR, width: faceR * 2, height: faceR * 2))
    ctx.setFillColor(color(0x141C24))
    ctx.fillPath()

    // Latch notch at the top of the face.
    ctx.addRect(CGRect(x: center.x - 22, y: center.y + faceR - 30, width: 44, height: 40))
    ctx.setFillColor(color(0x9AA6AE))
    ctx.fillPath()

    // 5 pins: 4 on a circle + 1 centre, in the stage-light amber.
    let pinR: CGFloat = 26
    let pinOrbit: CGFloat = 88
    var pins = [center]
    for deg in [210.0, 150.0, 330.0, 30.0] {
        let a = deg * .pi / 180
        pins.append(CGPoint(x: center.x + pinOrbit * cos(a), y: center.y + pinOrbit * sin(a)))
    }
    for p in pins {
        ctx.addEllipse(in: CGRect(x: p.x - pinR, y: p.y - pinR, width: pinR * 2, height: pinR * 2))
        ctx.setFillColor(color(0xFFC247))
        ctx.fillPath()
    }
}

func render(size: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconsetDir.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconsetDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsPath]
try p.run()
p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: iconsetDir)
try render(size: 1024).write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
print("wrote \(icnsPath) and Resources/AppIcon-1024.png")
