import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

// Renders the AutoRenew icons: the signature-purple gradient with a white circular
// refresh arrow (⟳).
//   1. The macOS app icon (rounded tile, transparent outside — Big Sur style).
//   2. The menu-bar template glyph (white on transparent).
// Usage: swift make_icon.swift <app-icon.png> <menubar.png>

func writePNG(_ image: CGImage, to path: String) {
    #if canImport(UniformTypeIdentifiers)
    let utType = UTType.png.identifier
    #else
    let utType = "public.png"
    #endif
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, utType as CFString, 1, nil) else {
        fatalError("could not create image destination at \(path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write png to \(path)") }
    print("wrote \(path)")
}

/// Draws the white refresh glyph (ring with a gap + arrowhead) centred in the context.
func drawRefreshGlyph(_ ctx: CGContext, center: CGPoint, radius: CGFloat) {
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

    let lineWidth = radius * 0.25
    ctx.setLineWidth(lineWidth)
    ctx.setLineCap(.round)

    // Ring with a ~70° gap at the top-right; angles in radians, 0 = right, CCW positive.
    let gapCenter: CGFloat = .pi * 0.25
    let gapHalf: CGFloat = .pi * 0.19
    let from = gapCenter + gapHalf
    let to = gapCenter - gapHalf + 2 * .pi
    ctx.addArc(center: center, radius: radius, startAngle: from, endAngle: to, clockwise: false)
    ctx.strokePath()

    // Arrowhead at the arc's end (angle `to`), pointing clockwise along the ring.
    let arrowAngle: CGFloat = gapCenter - gapHalf
    let tip = CGPoint(x: center.x + radius * cos(arrowAngle),
                      y: center.y + radius * sin(arrowAngle))
    let ah = radius * 0.285          // arrow length along the tangent
    let ahWidth = radius * 0.37      // arrow width across the normal
    let tangent = CGPoint(x: -sin(arrowAngle), y: cos(arrowAngle))
    let normal = CGPoint(x: cos(arrowAngle), y: sin(arrowAngle))

    let p1 = CGPoint(x: tip.x + tangent.x * ah, y: tip.y + tangent.y * ah)
    let p2 = CGPoint(x: tip.x - tangent.x * ah * 0.15 + normal.x * ahWidth * 0.5,
                     y: tip.y - tangent.y * ah * 0.15 + normal.y * ahWidth * 0.5)
    let p3 = CGPoint(x: tip.x - tangent.x * ah * 0.15 - normal.x * ahWidth * 0.5,
                     y: tip.y - tangent.y * ah * 0.15 - normal.y * ahWidth * 0.5)

    ctx.move(to: p1)
    ctx.addLine(to: p2)
    ctx.addLine(to: p3)
    ctx.closePath()
    ctx.fillPath()
}

func makeContext(size: Int) -> CGContext {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create CGContext")
    }
    return ctx
}

let args = CommandLine.arguments
let appIconPath = args.count > 1 ? args[1] : "AppIcon.png"
let menuBarPath = args.count > 2 ? args[2] : "MenuBar.png"

#if canImport(CoreGraphics) && canImport(ImageIO)

// MARK: - App icon (1024×1024, transparent margins + rounded tile)

let appSize = 1024
let appCtx = makeContext(size: appSize)
let w = CGFloat(appSize)

// macOS icon grid: 824×824 tile centred in the 1024 canvas, corner radius ≈ 22.37 %.
let tileSide = w * 0.824
let tileOrigin = (w - tileSide) / 2
let tileRect = CGRect(x: tileOrigin, y: tileOrigin, width: tileSide, height: tileSide)
let cornerRadius = tileSide * 0.2237

appCtx.addPath(CGPath(roundedRect: tileRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
appCtx.clip()

// Purple vertical gradient (matches the signature purple palette)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let topColor = CGColor(red: 0.35, green: 0.26, blue: 0.72, alpha: 1.0)
let bottomColor = CGColor(red: 0.60, green: 0.45, blue: 0.94, alpha: 1.0)
if let grad = CGGradient(colorsSpace: space, colors: [topColor, bottomColor] as CFArray, locations: [0.0, 1.0]) {
    appCtx.drawLinearGradient(grad, start: CGPoint(x: w / 2, y: tileRect.minY), end: CGPoint(x: w / 2, y: tileRect.maxY), options: [])
}

// Soft highlight across the top half for a little depth
if let gloss = CGGradient(colorsSpace: space,
                          colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
                                   CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
                          locations: [0.0, 1.0]) {
    appCtx.drawLinearGradient(gloss,
                              start: CGPoint(x: w / 2, y: tileRect.maxY),
                              end: CGPoint(x: w / 2, y: tileRect.midY),
                              options: [])
}

drawRefreshGlyph(appCtx, center: CGPoint(x: w / 2, y: w / 2), radius: tileSide * 0.30)

guard let appImage = appCtx.makeImage() else { fatalError("could not make app icon CGImage") }
writePNG(appImage, to: appIconPath)

// MARK: - Menu-bar glyph (72×72 backing an 18 pt template image)

let barSize = 72
let barCtx = makeContext(size: barSize)
let b = CGFloat(barSize)
drawRefreshGlyph(barCtx, center: CGPoint(x: b / 2, y: b / 2), radius: b * 0.31)

guard let barImage = barCtx.makeImage() else { fatalError("could not make menu bar CGImage") }
writePNG(barImage, to: menuBarPath)

#else
fatalError("CoreGraphics/ImageIO unavailable")
#endif
