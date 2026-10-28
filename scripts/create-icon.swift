// Build with the shared renderer prepended; see scripts/build.sh.
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: create-icon.swift <output.iconset> <output.icns>\n", stderr)
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func drawIcon(size: Int) throws -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale)
    (transform as NSAffineTransform).concat()

    let base = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 205, yRadius: 205)
    let charcoal = NSColor(srgbRed: 0.075, green: 0.105, blue: 0.095, alpha: 1)
    let charcoalLight = NSColor(srgbRed: 0.16, green: 0.22, blue: 0.19, alpha: 1)
    NSGradient(starting: charcoalLight, ending: charcoal)!.draw(in: base, angle: -90)
    let rim = NSBezierPath(roundedRect: NSRect(x: 58, y: 58, width: 908, height: 908), xRadius: 203, yRadius: 203)
    NSColor.white.withAlphaComponent(0.08).setStroke()
    rim.lineWidth = 2
    rim.stroke()

    // The same Lucide vector mark used by the menu bar and Clean desk action.
    let mint = NSColor(srgbRed: 0.52, green: 0.90, blue: 0.74, alpha: 1)
    CleanDeskIcon.draw(in: NSRect(x: 150, y: 150, width: 724, height: 724), color: mint)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for factor in [1, 2] {
        let suffix = factor == 2 ? "@2x" : ""
        let filename = "icon_\(points)x\(points)\(suffix).png"
        try drawIcon(size: points * factor).write(to: output.appendingPathComponent(filename))
    }
}

// An ICNS file is a big-endian length-prefixed container. Modern icon
// representations store PNG payloads; writing these directly also works when
// iconutil's system encoder is unavailable in the build environment.
func bigEndianBytes(_ value: UInt32) -> Data {
    var number = value.bigEndian
    return withUnsafeBytes(of: &number) { Data($0) }
}

let representations: [(String, String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]
var chunks = Data()
for (type, filename) in representations {
    let png = try Data(contentsOf: output.appendingPathComponent(filename))
    chunks.append(contentsOf: type.utf8)
    chunks.append(bigEndianBytes(UInt32(png.count + 8)))
    chunks.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndianBytes(UInt32(chunks.count + 8)))
icns.append(chunks)
let iconURL = URL(fileURLWithPath: CommandLine.arguments[2])
try icns.write(to: iconURL)
guard let image = NSImage(contentsOf: iconURL), image.isValid else {
    fputs("Generated ICNS could not be decoded by AppKit.\n", stderr)
    exit(1)
}
