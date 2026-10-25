import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// Deterministic export/composition only. Screenshot pixels come from Simulator.
struct Scene: Decodable { let id: String; let headline: String; let detail: String }
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "output/app-store/2026-10", isDirectory: true)
let scenes = try JSONDecoder().decode([Scene].self, from: Data(contentsOf: root.appendingPathComponent("scenes.json")))
let mint = CGColor(red: 0.35, green: 0.95, blue: 0.72, alpha: 1)
let navy = CGColor(red: 0.035, green: 0.065, blue: 0.085, alpha: 1)
let white = CGColor(gray: 1, alpha: 1)

func image(_ url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
func export(_ url: URL, width: Int, height: Int, drawing: (CGContext, CGRect) -> Void) throws {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.interpolationQuality = .high
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    context.setFillColor(navy); context.fill(bounds)
    drawing(context, bounds)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil), let result = context.makeImage() else { fatalError("Cannot create PNG") }
    CGImageDestinationAddImage(destination, result, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Cannot encode PNG") }
    print("Exported \(url.lastPathComponent): \(width)×\(height), RGB, opaque")
}
func fitted(_ image: CGImage, inside box: CGRect, fill: Bool = false) -> CGRect {
    let width = CGFloat(image.width), height = CGFloat(image.height)
    let scale = fill ? max(box.width / width, box.height / height) : min(box.width / width, box.height / height)
    let size = CGSize(width: width * scale, height: height * scale)
    return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
}
func text(_ value: String, rect: CGRect, size: CGFloat, bold: Bool = false, color: CGColor, context: CGContext) {
    let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
    let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color] as [CFString: Any]
    let string = CFAttributedStringCreate(nil, value as CFString, attributes as CFDictionary)!
    let setter = CTFramesetterCreateWithAttributedString(string)
    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
    CTFrameDraw(frame, context)
}
for (source, name, width, height) in [
    ("header-generated.png", "header-3840x1646.png", 3840, 1646),
    ("search-generated.png", "search-1920x1280.png", 1920, 1280)
] {
    if let photo = image(root.appendingPathComponent("sources/\(source)")) {
        try export(root.appendingPathComponent("artwork/\(name)"), width: width, height: height) { context, box in
            context.saveGState(); context.clip(to: box)
            context.draw(photo, in: fitted(photo, inside: box, fill: true))
            context.restoreGState()
        }
    }
}
for (family, width, height) in [("iphone", 1320, 2868), ("ipad", 2064, 2752)] {
    for (index, scene) in scenes.enumerated() {
        guard let screenImage = image(root.appendingPathComponent("raw/\(family)-\(scene.id).png")) else { continue }
        try export(root.appendingPathComponent("screenshots/\(family)-\(index + 1)-\(scene.id).png"), width: width, height: height) { context, box in
            let margin = box.width * 0.075
            text("MUX MANAGER", rect: CGRect(x: margin, y: box.height - margin - 40, width: box.width - 2 * margin, height: 45),
                 size: box.width * 0.023, color: mint, context: context)
            text(scene.headline.replacingOccurrences(of: "\\n", with: "\n"),
                 rect: CGRect(x: margin, y: box.height * 0.81, width: box.width - 2 * margin, height: box.height * 0.13),
                 size: box.width * (family == "iphone" ? 0.078 : 0.062), bold: true, color: white, context: context)
            text(scene.detail, rect: CGRect(x: margin, y: box.height * 0.745, width: box.width - 2 * margin, height: box.height * 0.065),
                 size: box.width * 0.031, color: CGColor(gray: 0.72, alpha: 1), context: context)
            let screen = fitted(screenImage, inside: CGRect(x: margin, y: box.height * 0.025, width: box.width - 2 * margin, height: box.height * 0.70))
            context.setFillColor(CGColor(gray: 0.20, alpha: 1))
            context.addPath(CGPath(roundedRect: screen.insetBy(dx: -12, dy: -12), cornerWidth: 32, cornerHeight: 32, transform: nil)); context.fillPath()
            context.saveGState()
            context.addPath(CGPath(roundedRect: screen, cornerWidth: 23, cornerHeight: 23, transform: nil)); context.clip()
            context.draw(screenImage, in: screen)
            context.restoreGState()
        }
    }
}

let finals = ["iphone", "ipad"].flatMap { family in
    scenes.enumerated().map { index, scene in root.appendingPathComponent("screenshots/\(family)-\(index + 1)-\(scene.id).png") }
}
if finals.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
    try export(root.appendingPathComponent("contact-sheet.png"), width: 2000, height: 1600) { context, _ in
        for (index, url) in finals.enumerated() {
            guard let screen = image(url) else { continue }
            let box = CGRect(x: (index % 5) * 400 + 15, y: (index < 5 ? 800 : 0) + 15, width: 370, height: 770)
            context.draw(screen, in: fitted(screen, inside: box))
        }
    }
}
