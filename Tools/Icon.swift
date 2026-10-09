import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
func draw(_ size: Int) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = AffineTransform(scale: scale); (transform as NSAffineTransform).concat()
    let rect = NSRect(x: 72, y: 72, width: 880, height: 880)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 198, yRadius: 198)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18); shadow.shadowBlurRadius = 25; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    NSGradient(starting: NSColor(red: 0.18, green: 0.50, blue: 0.98, alpha: 1), ending: NSColor(red: 0.10, green: 0.29, blue: 0.77, alpha: 1))!.draw(in: shape, angle: -90)
    NSShadow().set()
    let heights: [CGFloat] = [120, 245, 400, 290, 150]
    for (i, height) in heights.enumerated() {
        let bar = NSBezierPath(roundedRect: NSRect(x: 255 + CGFloat(i) * 104, y: 512 - height / 2, width: 56, height: height), xRadius: 28, yRadius: 28)
        NSColor.white.setFill(); bar.fill()
    }
    NSColor(red: 0.43, green: 0.98, blue: 0.83, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 698, y: 716, width: 85, height: 85)).fill()
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: folder.appendingPathComponent("icon_\(size)x\(size).png"))
}
for size in [16, 32, 64, 128, 256, 512, 1024] { try draw(size) }
for (base, double) in [(16,32),(32,64),(128,256),(256,512),(512,1024)] {
    try FileManager.default.copyItem(at: folder.appendingPathComponent("icon_\(double)x\(double).png"), to: folder.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
// iconutil accepts only its documented sizes; 64 and 1024 are represented as @2x.
try FileManager.default.removeItem(at: folder.appendingPathComponent("icon_64x64.png"))
try FileManager.default.removeItem(at: folder.appendingPathComponent("icon_1024x1024.png"))
