import AppKit

// Renders the vector source to every size the asset catalog needs.
// Exact pixel dimensions are forced via NSBitmapImageRep rather than
// NSImage.lockFocus, which would silently apply the display's 2x scale.
let svgPath = CommandLine.arguments[1]
let outDir  = CommandLine.arguments[2]

guard let source = NSImage(contentsOfFile: svgPath) else {
    FileHandle.standardError.write(Data("cannot load \(svgPath)\n".utf8)); exit(1)
}
source.size = NSSize(width: 1024, height: 1024)

func render(_ px: Int, to path: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: px, height: px),
                from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print("  \(px)x\(px) -> \((path as NSString).lastPathComponent)")
    }
}

// macOS app icon set: each logical size at 1x and 2x.
for base in [16, 32, 128, 256, 512] {
    render(base,     to: "\(outDir)/icon_\(base)x\(base).png")
    render(base * 2, to: "\(outDir)/icon_\(base)x\(base)@2x.png")
}
