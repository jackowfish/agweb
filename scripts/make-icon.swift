// Draws Resources/AppIcon.icns: a typing field (a dark pill holding three dots and a blue caret) on a white rounded square,
// for macOS 15. Then compiles Resources/AppIcon.icon (the same icon in layers, with a dark look: dark tile, white pill,
// dark dots) into Resources/Assets.car, which macOS 26 and later use instead; they
// show the dark look when System Settings > Appearance > Icon & widget style says Dark, or Automatic in Dark mode.
// Run: swift scripts/make-icon.swift (from the repo root; needs iconutil and Xcode's actool).
import AppKit

func bitmap(_ pixels: Int, draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

// Fills the current clip from the top of rect (first stop) to its bottom.
func vertical(_ cg: CGContext, _ rect: CGRect, _ stops: [(CGFloat, CGColor)]) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
    cg.drawLinearGradient(gradient, start: CGPoint(x: rect.midX, y: rect.minY), end: CGPoint(x: rect.midX, y: rect.maxY), options: [])
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath { CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil) }

// Drawn once at 1024 and scaled down. Coordinates are the tile's own, 824 points with y going down.
let master = bitmap(1024) {
    let cg = NSGraphicsContext.current!.cgContext
    // Apple's icon grid: an 824-point rounded square centered on the 1024 canvas.
    cg.translateBy(x: 100, y: 924)
    cg.scaleBy(x: 1, y: -1)
    let tileRect = CGRect(x: 0, y: 0, width: 824, height: 824)
    let tile = rounded(tileRect, 185)
    // Shadow offsets ignore the flip: negative height is down.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.3))
    cg.addPath(tile)
    cg.setFillColor(rgb(0xffffff))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(tile)
    cg.clip()
    vertical(cg, tileRect, [(0, rgb(0xffffff)), (1, rgb(0xe6e8ed))])

    // The field: a dark pill casting a soft shadow on the tile.
    let pillRect = CGRect(x: 92, y: 280, width: 640, height: 264)
    let pill = rounded(pillRect, 132)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.22))
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    cg.addPath(pill)
    cg.clip()
    vertical(cg, pillRect, [(0, rgb(0x2b2d33)), (1, rgb(0x0c0d10))])
    cg.endTransparencyLayer()
    cg.restoreGState()

    // Typed text as three dots, then the caret.
    cg.setFillColor(rgb(0xffffff))
    for x in [220, 328, 436] as [CGFloat] { cg.fillEllipse(in: CGRect(x: x - 44, y: 368, width: 88, height: 88)) }
    cg.addPath(rounded(CGRect(x: 516, y: 330, width: 46, height: 164), 13))
    cg.setFillColor(rgb(0x3d9cff))
    cg.fillPath()

    // A rim: lighter along the top edge, darker along the bottom.
    cg.addPath(rounded(tileRect.insetBy(dx: 3, dy: 3), 182))
    cg.setLineWidth(6)
    cg.replacePathWithStrokedPath()
    cg.clip()
    vertical(cg, tileRect, [(0, rgb(0xffffff, 0.45)), (0.25, rgb(0xffffff, 0)), (0.8, rgb(0x000000, 0)), (1, rgb(0x000000, 0.18))])
    cg.restoreGState()
}

func render(_ pixels: Int) -> Data {
    bitmap(pixels) { master.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024)) }.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")

// actool also writes a 256-pixel AppIcon.icns of its own; the one drawn above is kept.
let compiled = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.compiled")
try? FileManager.default.removeItem(at: compiled)
try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
let actool = Process()
actool.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
actool.arguments = ["actool", FileManager.default.currentDirectoryPath + "/Resources/AppIcon.icon", "--compile", compiled.path, "--platform", "macosx", "--target-device", "mac",
                    "--minimum-deployment-target", "15.4", "--app-icon", "AppIcon",
                    "--output-partial-info-plist", compiled.appendingPathComponent("partial.plist").path]
actool.standardOutput = FileHandle.nullDevice
try actool.run()
actool.waitUntilExit()
let car = compiled.appendingPathComponent("Assets.car")
guard actool.terminationStatus == 0, FileManager.default.fileExists(atPath: car.path) else { print("actool failed"); exit(1) }
try? FileManager.default.removeItem(atPath: "Resources/Assets.car")
try FileManager.default.copyItem(at: car, to: URL(fileURLWithPath: "Resources/Assets.car"))
print("wrote Resources/Assets.car")
