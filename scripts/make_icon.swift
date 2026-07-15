// Renders the Swara app icon: three mixer faders on a blue→indigo squircle.
// Usage: swift scripts/make_icon.swift <output_1024.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let side = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("context")
}
let W = CGFloat(side), H = CGFloat(side)

// Squircle body with a transparent margin (macOS icon grid convention).
let margin: CGFloat = 100
let body = CGRect(x: margin, y: margin, width: W - 2 * margin, height: H - 2 * margin)
let radius = body.width * 0.2237
let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Diagonal gradient background.
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let grad = CGGradient(colorsSpace: cs,
                      colors: [CGColor(red: 0.18, green: 0.49, blue: 0.965, alpha: 1),
                               CGColor(red: 0.545, green: 0.239, blue: 0.941, alpha: 1)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad,
                       start: CGPoint(x: body.minX, y: body.maxY),
                       end: CGPoint(x: body.maxX, y: body.minY), options: [])
ctx.restoreGState()

// Three faders: translucent track + white knob at varying heights.
let trackH = body.height * 0.60
let trackW: CGFloat = 64
let knobR: CGFloat = 58
let centerY = H / 2
let bottom = centerY - trackH / 2
let columns: [(x: CGFloat, knobFrac: CGFloat)] = [
    (body.midX - 200, 0.28),
    (body.midX,       0.70),
    (body.midX + 200, 0.48),
]

for col in columns {
    let track = CGRect(x: col.x - trackW / 2, y: bottom, width: trackW, height: trackH)
    ctx.addPath(CGPath(roundedRect: track, cornerWidth: trackW / 2, cornerHeight: trackW / 2, transform: nil))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.30))
    ctx.fillPath()

    let knobY = bottom + col.knobFrac * trackH
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: col.x - knobR, y: knobY - knobR, width: knobR * 2, height: knobR * 2))
    ctx.restoreGState()
}

guard let image = ctx.makeImage() else { fatalError("image") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("dest")
}
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("write") }
print("wrote \(out.path)")
