import AppKit

func makeAppIcon(size: Int) -> NSImage {
    let s = CGFloat(size)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus()
        return img
    }
    
    // Canvas dimensions
    let margin = s * 0.1
    let iconSize = s - (margin * 2)
    let iconRect = CGRect(x: margin, y: margin, width: iconSize, height: iconSize)
    let cornerRadius = iconSize * 0.225
    
    // 1. Drop shadow for the squircle
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.04), blur: s * 0.08, color: NSColor.black.withAlphaComponent(0.45).cgColor)
    let path = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    
    // 2. Background Squircle with Gradient
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(red: 0.12, green: 0.14, blue: 0.28, alpha: 1.0).cgColor, // Top indigo
        NSColor(red: 0.06, green: 0.07, blue: 0.15, alpha: 1.0).cgColor  // Bottom dark navy
    ] as CFArray
    let bgGradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: iconRect.midX, y: iconRect.maxY), end: CGPoint(x: iconRect.midX, y: iconRect.minY), options: [])
    
    // Inner radial glow
    let glowColors = [
        NSColor(red: 0.38, green: 0.40, blue: 0.95, alpha: 0.35).cgColor,
        NSColor(red: 0.38, green: 0.40, blue: 0.95, alpha: 0.0).cgColor
    ] as CFArray
    let glowGradient = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(glowGradient, startCenter: CGPoint(x: iconRect.midX, y: iconRect.midY + iconSize * 0.1), startRadius: 0, endCenter: CGPoint(x: iconRect.midX, y: iconRect.midY), endRadius: iconSize * 0.6, options: [])
    
    // Border highlight
    ctx.setLineWidth(s * 0.008)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.2).cgColor)
    ctx.addPath(path)
    ctx.strokePath()
    ctx.restoreGState()
    
    // 3. Draw Tabler Language Icon SVG on top
    // SVG viewBox is 0 0 24 24
    let glyphScale = (iconSize * 0.58) / 24.0
    let glyphOffsetX = iconRect.midX - (12.0 * glyphScale)
    let glyphOffsetY = iconRect.midY - (12.0 * glyphScale)
    
    ctx.saveGState()
    // Map SVG coordinates (Y down in SVG, Y up in CoreGraphics)
    ctx.translateBy(x: glyphOffsetX, y: glyphOffsetY + 24.0 * glyphScale)
    ctx.scaleBy(x: glyphScale, y: -glyphScale)
    
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(2.0)
    
    // Draw glow / shadow under stroke
    ctx.setShadow(offset: CGSize(width: 0, height: -0.8), blur: 2.0, color: NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 0.6).cgColor)
    
    let strokeColor = NSColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 1.0).cgColor
    ctx.setStrokeColor(strokeColor)
    
    // Path 1: M4 5h7
    ctx.move(to: CGPoint(x: 4, y: 5))
    ctx.addLine(to: CGPoint(x: 11, y: 5))
    
    // Path 2: M9 3v2c0 4.418 -2.239 8 -5 9
    ctx.move(to: CGPoint(x: 9, y: 3))
    ctx.addLine(to: CGPoint(x: 9, y: 5))
    ctx.addCurve(to: CGPoint(x: 4, y: 14), control1: CGPoint(x: 9, y: 5 + 4.418), control2: CGPoint(x: 9 - 2.239, y: 5 + 8))
    
    // Path 3: M5 9c0 2.144 2.952 3.908 6.7 4
    ctx.move(to: CGPoint(x: 5, y: 9))
    ctx.addCurve(to: CGPoint(x: 5 + 6.7, y: 9 + 4), control1: CGPoint(x: 5, y: 9 + 2.144), control2: CGPoint(x: 5 + 2.952, y: 9 + 3.908))
    
    // Path 4: M12 20l4 -9l4 9
    ctx.move(to: CGPoint(x: 12, y: 20))
    ctx.addLine(to: CGPoint(x: 16, y: 11))
    ctx.addLine(to: CGPoint(x: 20, y: 20))
    
    // Path 5: M19.1 18h-6.2
    ctx.move(to: CGPoint(x: 19.1, y: 18))
    ctx.addLine(to: CGPoint(x: 12.9, y: 18))
    
    ctx.strokePath()
    ctx.restoreGState()
    
    img.unlockFocus()
    return img
}

let scriptDir = URL(fileURLWithPath: #file).deletingLastPathComponent().path
let rootDir = URL(fileURLWithPath: scriptDir).deletingLastPathComponent().path
let assetsDir = "\(rootDir)/assets"
let iconsetDir = "\(assetsDir)/AppIcon.iconset"
let icnsPath = "\(assetsDir)/AppIcon.icns"

let fileManager = FileManager.default
try? fileManager.removeItem(atPath: iconsetDir)
try? fileManager.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, size) in sizes {
    let img = makeAppIcon(size: size)
    if let tiff = img.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        let url = URL(fileURLWithPath: "\(iconsetDir)/\(filename)")
        try? png.write(to: url)
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
try? task.run()
task.waitUntilExit()

try? fileManager.removeItem(atPath: iconsetDir)
print("Successfully generated \(icnsPath)")
