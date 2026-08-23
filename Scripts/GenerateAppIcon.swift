// Renders the app icon (window grid, top-left tile selected — mirrors the
// palette's own UI) directly via Core Graphics at every size macOS needs,
// so there's no dependency on an SVG rasterizer. Re-run after any tweak:
//   swift Scripts/GenerateAppIcon.swift AppIcon.iconset
//   iconutil -c icns AppIcon.iconset -o Resources/AppIcon.icns

import AppKit
import CoreGraphics

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func renderIcon(size: Int) -> Data {
    let s = CGFloat(size)
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not create context") }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Background squircle.
    let bgRadius = s * 0.2167
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                        cornerWidth: bgRadius, cornerHeight: bgRadius, transform: nil))
    ctx.setFillColor(rgb(0x26, 0x2b, 0x36))
    ctx.fillPath()

    // 2x2 grid, top-left tile "selected" — same shape language as the palette.
    let cellW = s * 0.35, cellH = s * 0.25, gap = s * 0.05, cellCorner = s * 0.0417
    let gridW = cellW * 2 + gap
    let startX = (s - gridW) / 2
    let topRowY = s / 2 + gap / 2
    let bottomRowY = s / 2 - gap / 2 - cellH
    let col1X = startX, col2X = startX + cellW + gap

    func fillCell(x: CGFloat, y: CGFloat, selected: Bool) {
        let path = CGPath(roundedRect: CGRect(x: x, y: y, width: cellW, height: cellH),
                           cornerWidth: cellCorner, cornerHeight: cellCorner, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(selected ? rgb(242, 245, 250) : rgb(0xc7, 0xcf, 0xda))
        ctx.fillPath()
        if selected {
            ctx.addPath(path)
            ctx.setStrokeColor(rgb(0x4f, 0x8c, 0xff))
            ctx.setLineWidth(s * 0.025)
            ctx.strokePath()
        }
    }
    fillCell(x: col1X, y: topRowY, selected: true)
    fillCell(x: col2X, y: topRowY, selected: false)
    fillCell(x: col1X, y: bottomRowY, selected: false)
    fillCell(x: col2X, y: bottomRowY, selected: false)

    guard let cgImage = ctx.makeImage() else { fatalError("could not make image") }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("could not encode png") }
    return data
}

let specs: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for spec in specs {
    let data = renderIcon(size: spec.size)
    try! data.write(to: URL(fileURLWithPath: outDir + "/" + spec.name))
    print("wrote \(spec.name)")
}
