import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon convention: rounded-rect (squircle-ish) filling most of canvas with a
// small transparent margin. margin ~ 10% -> content rect.
let margin: CGFloat = S * 0.086
let rect = CGRect(x: margin, y: margin, width: S - 2*margin, height: S - 2*margin)
let radius = rect.width * 0.2237
let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
path.addClip()

// Diagonal blue gradient (Xcode "blueprint" blue)
let colors = [NSColor(srgbRed: 0.15, green: 0.55, blue: 0.98, alpha: 1).cgColor,
              NSColor(srgbRed: 0.05, green: 0.35, blue: 0.88, alpha: 1).cgColor]
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: colors as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

// Blueprint grid pattern — thin light lines, like Xcode / Simulator icons
ctx.saveGState()
ctx.setStrokeColor(NSColor(white: 1, alpha: 0.10).cgColor)
ctx.setLineWidth(S * 0.004)
let step = rect.width / 8
var g = rect.minX
while g <= rect.maxX + 1 {
    ctx.move(to: CGPoint(x: g, y: rect.minY)); ctx.addLine(to: CGPoint(x: g, y: rect.maxY))
    g += step
}
g = rect.minY
while g <= rect.maxY + 1 {
    ctx.move(to: CGPoint(x: rect.minX, y: g)); ctx.addLine(to: CGPoint(x: rect.maxX, y: g))
    g += step
}
ctx.strokePath()
ctx.restoreGState()

// Subtle top sheen
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [NSColor(white: 1, alpha: 0.18).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: rect.midX, y: rect.maxY),
                       end: CGPoint(x: rect.midX, y: rect.midY), options: [])

// SF Symbol gauge 50%, white, centered
let cfg = NSImage.SymbolConfiguration(pointSize: S * 0.5, weight: .light)
    .applying(.init(paletteColors: [.white]))
let sym = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent",
                  accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let sw = sym.size.width, sh = sym.size.height
let scale = (rect.width * 0.86) / max(sw, sh)
let dw = sw * scale, dh = sh * scale
let dst = CGRect(x: rect.midX - dw/2, y: rect.midY - dh/2, width: dw, height: dh)
// soft shadow behind symbol
ctx.setShadow(offset: CGSize(width: 0, height: -S*0.008), blur: S*0.02,
              color: NSColor(white: 0, alpha: 0.25).cgColor)
sym.draw(in: dst)

img.unlockFocus()

// Export 1024 master PNG
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: "/tmp/appicon_1024.png"))
print("wrote /tmp/appicon_1024.png")
