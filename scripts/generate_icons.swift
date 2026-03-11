import AppKit

func pngData(from image: NSImage) -> Data? {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff) else {
        return nil
    }
    return bitmap.representation(using: .png, properties: [:])
}

func resizedImage(from source: NSImage, size: CGFloat) -> NSImage {
    let pixels = Int(size)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return source
    }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current = context
    context?.imageInterpolation = .high
    source.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: NSRect(origin: .zero, size: source.size),
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    let image = NSImage(size: NSSize(width: size, height: size))
    image.addRepresentation(bitmap)
    return image
}

func renderMenuBarIcon(size: CGFloat, darkMode: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.isTemplate = true
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let color = darkMode ? NSColor.white : NSColor.black
    let centerX = size / 2
    let top = size * 0.14
    let bottom = size * 0.86
    let shortTop = size * 0.27
    let shortBottom = size * 0.73
    let midTop = size * 0.18
    let midBottom = size * 0.82
    let spread = size * 0.16

    func drawBar(x: CGFloat, y0: CGFloat, y1: CGFloat, width: CGFloat) {
        let rect = CGRect(x: x - width / 2, y: y0, width: width, height: y1 - y0)
        let path = CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }

    drawBar(x: centerX - spread, y0: shortTop, y1: shortBottom, width: size * 0.10)
    drawBar(x: centerX - spread * 0.42, y0: midTop, y1: midBottom, width: size * 0.14)
    drawBar(x: centerX, y0: top, y1: bottom, width: size * 0.07)
    drawBar(x: centerX + spread * 0.42, y0: midTop, y1: midBottom, width: size * 0.14)
    drawBar(x: centerX + spread, y0: shortTop, y1: shortBottom, width: size * 0.10)

    image.unlockFocus()
    return image
}

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let sourceURL = root.appendingPathComponent("design/Gemini_Generated_Image_eoyi5meoyi5meoyi.png")
let assetsURL = root.appendingPathComponent("Tono/Assets.xcassets", isDirectory: true)
let appIconURL = assetsURL.appendingPathComponent("AppIcon.appiconset", isDirectory: true)
let menuBarURL = assetsURL.appendingPathComponent("MenuBarIcon.imageset", isDirectory: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    throw NSError(domain: "IconGeneration", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to load source image at \(sourceURL.path)"])
}

try fileManager.createDirectory(at: appIconURL, withIntermediateDirectories: true)
try fileManager.createDirectory(at: menuBarURL, withIntermediateDirectories: true)

let appIconSizes = [16, 32, 64, 128, 256, 512, 1024]
for size in appIconSizes {
    let image = resizedImage(from: sourceImage, size: CGFloat(size))
    let url = appIconURL.appendingPathComponent("icon_\(size)x\(size).png")
    guard let data = pngData(from: image) else {
        throw NSError(domain: "IconGeneration", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode \(url.lastPathComponent)"])
    }
    try data.write(to: url)
}

let menuBarOutputs: [(NSImage, String)] = [
    (renderMenuBarIcon(size: 18, darkMode: true), "menubar.png"),
    (renderMenuBarIcon(size: 36, darkMode: true), "menubar@2x.png"),
    (renderMenuBarIcon(size: 18, darkMode: false), "menubar-light.png"),
    (renderMenuBarIcon(size: 36, darkMode: false), "menubar-light@2x.png")
]

for (image, name) in menuBarOutputs {
    let url = menuBarURL.appendingPathComponent(name)
    guard let data = pngData(from: image) else {
        throw NSError(domain: "IconGeneration", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode \(name)"])
    }
    try data.write(to: url)
}

print("Generated icon assets from \(sourceURL.lastPathComponent)")
