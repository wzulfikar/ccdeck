import AppKit

// DMG background: soft brand-blue gradient + dashed curved arrow pointing from
// the app icon (left) to the Applications symlink (right). Rendered at @1x
// (600x400) and @2x (1200x800) to match the Finder window in bundle.sh.
// Icon centers in the window (top-left origin): app {150,200}, Apps {450,200}.

func render(scale: CGFloat, to path: String) {
    let W: CGFloat = 600 * scale, H: CGFloat = 400 * scale
    // Explicit bitmap rep at exact pixel dims — avoids the main screen's Retina
    // backing scale doubling the output of NSImage.lockFocus().
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Soft brand-blue gradient (light so dark icon labels stay readable).
    let colors = [NSColor(srgbRed: 0.86, green: 0.93, blue: 1.00, alpha: 1).cgColor,
                  NSColor(srgbRed: 0.72, green: 0.85, blue: 0.99, alpha: 1).cgColor]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H),
                           end: CGPoint(x: 0, y: 0), options: [])

    // Dashed curved arrow. AppKit origin is bottom-left, so y is measured up.
    // Vertical middle of the window (icon centers) is y = H/2.
    let s = scale
    let start = CGPoint(x: 232 * s, y: H/2)          // just right of the app icon
    let end   = CGPoint(x: 356 * s, y: H/2)          // just left of Applications
    let ctrl  = CGPoint(x: (start.x + end.x)/2, y: H/2 + 26 * s)  // arch upward

    ctx.setStrokeColor(NSColor(white: 0.10, alpha: 0.80).cgColor)
    ctx.setLineWidth(6 * s)
    ctx.setLineCap(.round)
    ctx.setLineDash(phase: 0, lengths: [0.1 * s, 14 * s]) // round dots via .round cap
    ctx.move(to: start)
    ctx.addQuadCurve(to: end, control: ctrl)
    ctx.strokePath()

    // Arrowhead (solid) at the end, angled along the curve tangent.
    // Tangent of a quad bezier at t=1 points from ctrl -> end.
    let ang = atan2(end.y - ctrl.y, end.x - ctrl.x)
    let hx: CGFloat = 20 * s          // head length
    let hw: CGFloat = 13 * s          // half-width
    ctx.setLineDash(phase: 0, lengths: [])
    ctx.setFillColor(NSColor(white: 0.10, alpha: 0.90).cgColor)
    let tip = CGPoint(x: end.x + 6 * s * cos(ang), y: end.y + 6 * s * sin(ang))
    let back = CGPoint(x: tip.x - hx * cos(ang), y: tip.y - hx * sin(ang))
    let left  = CGPoint(x: back.x - hw * sin(ang), y: back.y + hw * cos(ang))
    let right = CGPoint(x: back.x + hw * sin(ang), y: back.y - hw * cos(ang))
    ctx.move(to: tip)
    ctx.addLine(to: left)
    ctx.addLine(to: right)
    ctx.closePath()
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()

    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(Int(W))x\(Int(H)))")
}

render(scale: 1, to: "scripts/utils/dmg-background.png")
render(scale: 2, to: "scripts/utils/dmg-background@2x.png")
