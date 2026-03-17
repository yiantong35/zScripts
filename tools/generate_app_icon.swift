import AppKit
import Foundation

struct IconSpec {
    let filename: String
    let size: CGFloat
}

let specs: [IconSpec] = [
    .init(filename: "icon_16x16.png", size: 16),
    .init(filename: "icon_16x16@2x.png", size: 32),
    .init(filename: "icon_32x32.png", size: 32),
    .init(filename: "icon_32x32@2x.png", size: 64),
    .init(filename: "icon_128x128.png", size: 128),
    .init(filename: "icon_128x128@2x.png", size: 256),
    .init(filename: "icon_256x256.png", size: 256),
    .init(filename: "icon_256x256@2x.png", size: 512),
    .init(filename: "icon_512x512.png", size: 512),
    .init(filename: "icon_512x512@2x.png", size: 1024),
]

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> NSColor {
    NSColor(calibratedRed: r / 255.0, green: g / 255.0, blue: b / 255.0, alpha: a)
}

func roundedRect(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func fillRoundedRect(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor? = nil, lineWidth: CGFloat = 1.0) {
    let path = roundedRect(in: rect, radius: radius)
    fill.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = lineWidth
        path.stroke()
    }
}

func drawCable(_ context: CGContext, points: [CGPoint], width: CGFloat, stroke: NSColor, shadow: NSColor? = nil) {
    guard points.count > 1 else { return }
    let path = CGMutablePath()
    path.move(to: points[0])
    for idx in stride(from: 1, to: points.count, by: 3) {
        if idx + 2 < points.count {
            path.addCurve(to: points[idx + 2], control1: points[idx], control2: points[idx + 1])
        } else {
            path.addLine(to: points[idx])
        }
    }

    if let shadow {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(width * 1.22)
        context.setStrokeColor(shadow.cgColor)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    context.saveGState()
    context.setLineCap(.round)
    context.setLineWidth(width)
    context.setStrokeColor(stroke.cgColor)
    context.addPath(path)
    context.strokePath()
    context.restoreGState()
}

func drawBackground(size: CGFloat) {
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let gradient = NSGradient(colors: [
        color(18, 18, 20),
        color(26, 26, 29),
        color(12, 12, 14),
    ])!
    gradient.draw(in: rect, angle: -18.0)

    color(8, 8, 9, 0.22).setFill()
    NSBezierPath(rect: rect).fill()
}

func drawDevice(size: CGFloat) {
    let shadowRect = NSRect(x: size * 0.20, y: size * 0.13, width: size * 0.60, height: size * 0.13)
    fillRoundedRect(shadowRect, radius: size * 0.06, fill: color(0, 0, 0, 0.24))

    let pivot = NSPoint(x: size * 0.50, y: size * 0.51)
    let bodySize = NSSize(width: size * 0.60, height: size * 0.46)

    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.saveGState()
    ctx.translateBy(x: pivot.x, y: pivot.y)
    ctx.rotate(by: -0.23)

    let bodyRect = NSRect(
        x: -bodySize.width * 0.5,
        y: -bodySize.height * 0.5,
        width: bodySize.width,
        height: bodySize.height
    )
    fillRoundedRect(
        bodyRect,
        radius: size * 0.034,
        fill: color(21, 21, 22),
        stroke: color(67, 67, 70, 0.55),
        lineWidth: max(1.0, size * 0.004)
    )

    let finInsetX = bodyRect.width * 0.08
    let finInsetTop = bodyRect.height * 0.09
    let finInsetBottom = bodyRect.height * 0.24
    let finRect = NSRect(
        x: bodyRect.minX + finInsetX,
        y: bodyRect.minY + finInsetBottom,
        width: bodyRect.width - finInsetX * 1.18,
        height: bodyRect.height - finInsetTop - finInsetBottom
    )

    let finCount = max(8, Int(size / 34.0))
    for idx in 0..<finCount {
        let t = CGFloat(idx) / CGFloat(finCount - 1)
        let y = finRect.minY + t * finRect.height
        let line = NSBezierPath()
        line.lineCapStyle = .round
        line.lineWidth = max(1.0, size * 0.007)
        line.move(to: NSPoint(x: finRect.minX, y: y))
        line.line(to: NSPoint(x: finRect.maxX, y: y))
        color(82, 84, 88, 0.95).setStroke()
        line.stroke()

        let shadow = NSBezierPath()
        shadow.lineCapStyle = .round
        shadow.lineWidth = max(1.0, size * 0.005)
        shadow.move(to: NSPoint(x: finRect.minX, y: y - size * 0.004))
        shadow.line(to: NSPoint(x: finRect.maxX, y: y - size * 0.004))
        color(6, 6, 7, 0.55).setStroke()
        shadow.stroke()
    }

    let labelRect = NSRect(
        x: bodyRect.minX + bodyRect.width * 0.10,
        y: bodyRect.minY + bodyRect.height * 0.08,
        width: bodyRect.width * 0.46,
        height: bodyRect.height * 0.15
    )
    fillRoundedRect(labelRect, radius: size * 0.012, fill: color(27, 27, 28), stroke: color(72, 72, 74, 0.25), lineWidth: 1.0)

    if size >= 128 {
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.028, weight: .bold),
            .foregroundColor: color(232, 232, 236),
        ]
        NSAttributedString(string: "16G", attributes: textAttrs).draw(at: NSPoint(x: bodyRect.minX + bodyRect.width * 0.02, y: bodyRect.minY + bodyRect.height * 0.02))

        for idx in 0..<2 {
            let x = bodyRect.minX + bodyRect.width * (0.23 + CGFloat(idx) * 0.11)
            let y = bodyRect.minY + bodyRect.height * 0.04
            let buttonRect = NSRect(x: x, y: y, width: size * 0.022, height: size * 0.022)
            fillRoundedRect(buttonRect, radius: size * 0.011, fill: color(12, 12, 12), stroke: color(88, 88, 92, 0.35), lineWidth: 1.0)
        }
    }

    ctx.restoreGState()
}

func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else {
        return image
    }

    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)

    drawBackground(size: size)
    drawDevice(size: size)

    return image
}

func writePNG(image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "IconGen", code: 1)
    }
    try png.write(to: url)
}

func pngData(for size: CGFloat) throws -> Data {
    let image = makeIcon(size: size)
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let png = rep.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "IconGen", code: 2)
    }
    return png
}

func icnsChunk(type: String, pngData: Data) -> Data {
    var chunk = Data()
    chunk.append(type.data(using: .ascii)!)
    var length = UInt32(pngData.count + 8).bigEndian
    withUnsafeBytes(of: &length) { chunk.append(contentsOf: $0) }
    chunk.append(pngData)
    return chunk
}

func writeICNS(to url: URL) throws {
    let mapping: [(String, CGFloat)] = [
        ("icp4", 16),
        ("icp5", 32),
        ("icp6", 64),
        ("ic07", 128),
        ("ic08", 256),
        ("ic09", 512),
        ("ic10", 1024),
    ]

    var body = Data()
    for (type, size) in mapping {
        body.append(icnsChunk(type: type, pngData: try pngData(for: size)))
    }

    var header = Data()
    header.append("icns".data(using: .ascii)!)
    var totalLength = UInt32(body.count + 8).bigEndian
    withUnsafeBytes(of: &totalLength) { header.append(contentsOf: $0) }
    header.append(body)
    try header.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_app_icon.swift <output-directory|output.icns>\n", stderr)
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

if outputURL.pathExtension == "icns" {
    try writeICNS(to: outputURL)
} else {
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    for spec in specs {
        let icon = makeIcon(size: spec.size)
        try writePNG(image: icon, to: outputURL.appendingPathComponent(spec.filename))
    }
}
