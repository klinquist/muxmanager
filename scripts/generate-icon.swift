import AppKit
import CoreGraphics

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(red: 0.035, green: 0.07, blue: 0.09, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setFillColor(CGColor(red: 0.07, green: 0.14, blue: 0.17, alpha: 1))
context.addPath(CGPath(roundedRect: CGRect(x: 140, y: 165, width: 744, height: 694), cornerWidth: 58, cornerHeight: 58, transform: nil))
context.fillPath()
context.setStrokeColor(CGColor(red: 0.35, green: 0.95, blue: 0.72, alpha: 1))
context.setLineWidth(27)
context.setLineCap(.round)
context.setLineJoin(.round)
context.move(to: CGPoint(x: 183, y: 670)); context.addLine(to: CGPoint(x: 841, y: 670))
context.move(to: CGPoint(x: 365, y: 667)); context.addLine(to: CGPoint(x: 365, y: 825))
context.strokePath()
context.setLineWidth(43)
context.move(to: CGPoint(x: 272, y: 542)); context.addLine(to: CGPoint(x: 383, y: 442)); context.addLine(to: CGPoint(x: 272, y: 342))
context.move(to: CGPoint(x: 465, y: 340)); context.addLine(to: CGPoint(x: 665, y: 340))
context.strokePath()
for x in [208, 263, 318] {
    context.setFillColor(CGColor(red: 0.35, green: 0.95, blue: 0.72, alpha: x == 208 ? 1 : 0.35))
    context.fillEllipse(in: CGRect(x: x, y: 744, width: 22, height: 22))
}
let representation = NSBitmapImageRep(cgImage: context.makeImage()!)
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MuxManager/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
try representation.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
