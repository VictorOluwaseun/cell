import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                       ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
                       ("icon_512x512", 512), ("icon_512x512@2x", 1_024)] {
    let representation = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    let scale = Double(pixels) / 1_024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let box = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 200, yRadius: 200)
    NSColor(calibratedRed: 0.70, green: 0.62, blue: 1, alpha: 1).setFill(); box.fill()
    let ring = NSBezierPath(ovalIn: NSRect(x: 235, y: 235, width: 554, height: 554))
    ring.lineWidth = 52; NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.20, alpha: 1).setStroke(); ring.stroke()
    let bolt = NSBezierPath()
    bolt.move(to: NSPoint(x: 553, y: 737)); bolt.line(to: NSPoint(x: 367, y: 475))
    bolt.line(to: NSPoint(x: 494, y: 475)); bolt.line(to: NSPoint(x: 464, y: 289))
    bolt.line(to: NSPoint(x: 663, y: 563)); bolt.line(to: NSPoint(x: 530, y: 563)); bolt.close()
    NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.20, alpha: 1).setFill(); bolt.fill()
    NSGraphicsContext.restoreGraphicsState()
    let png = representation.representation(using: .png, properties: [:])!
    try png.write(to: directory.appendingPathComponent("\(name).png"))
}

// ICNS is a big-endian container of PNG representations. Assemble it directly
// so packaging does not depend on iconutil's out-of-process image services.
func integer(_ value: Int) -> Data {
    var bigEndian = UInt32(value).bigEndian
    return withUnsafeBytes(of: &bigEndian) { Data($0) }
}
var entries = Data()
for (type, name) in [("icp4", "icon_16x16"), ("icp5", "icon_32x32"), ("icp6", "icon_32x32@2x"),
                     ("ic07", "icon_128x128"), ("ic08", "icon_256x256"), ("ic09", "icon_512x512"),
                     ("ic10", "icon_512x512@2x"), ("ic11", "icon_16x16@2x"), ("ic12", "icon_32x32@2x"),
                     ("ic13", "icon_128x128@2x"), ("ic14", "icon_256x256@2x")] {
    let png = try Data(contentsOf: directory.appendingPathComponent("\(name).png"))
    entries.append(Data(type.utf8)); entries.append(integer(png.count + 8)); entries.append(png)
}
var icns = Data("icns".utf8); icns.append(integer(entries.count + 8)); icns.append(entries)
try icns.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
