import AppKit

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()

// ---- squircle ----
func squircle(_ rect: NSRect, n: CGFloat = 5.0) -> NSBezierPath {
    let p = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 1440
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { p.move(to: NSPoint(x: x, y: y)) } else { p.line(to: NSPoint(x: x, y: y)) }
    }
    p.close()
    return p
}

let body = NSRect(x: 62, y: 62, width: S - 124, height: S - 124)
let shape = squircle(body)

// drop shadow
NSGraphicsContext.saveGraphicsState()
let sh = NSShadow()
sh.shadowColor = NSColor.black.withAlphaComponent(0.20)
sh.shadowBlurRadius = 36
sh.shadowOffset = NSSize(width: 0, height: -16)
sh.set()
NSColor.white.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// background
NSGraphicsContext.saveGraphicsState()
shape.addClip()
let bg = NSGradient(colors: [
    NSColor(srgbRed: 0.99, green: 1.00, blue: 1.00, alpha: 1),
    NSColor(srgbRed: 0.85, green: 0.91, blue: 0.99, alpha: 1)
])!
bg.draw(in: body, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// ---- glyph: circular arrow + clock ----
let bold = NSColor(srgbRed: 0.07, green: 0.40, blue: 0.94, alpha: 1)
let cx = S / 2, cy = S / 2
let R: CGFloat = 250

// arc (gap at top-right for arrowhead)
let arc = NSBezierPath()
arc.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: R,
              startAngle: 40, endAngle: 330, clockwise: false)
arc.lineWidth = 62
arc.lineCapStyle = .round
bold.setStroke()
arc.stroke()

// arrowhead at arc end (40°)
let ang = 40.0 * .pi / 180
let tip = NSPoint(x: cx + R * cos(ang), y: cy + R * sin(ang))
let head = NSBezierPath()
head.move(to: NSPoint(x: tip.x + 30, y: tip.y + 92))
head.line(to: NSPoint(x: tip.x + 96, y: tip.y - 6))
head.line(to: NSPoint(x: tip.x + 6, y: tip.y - 40))
head.close()
bold.setFill()
head.fill()

// clock hands
let hands = NSBezierPath()
hands.lineWidth = 40
hands.lineCapStyle = .round
hands.move(to: NSPoint(x: cx, y: cy))
hands.line(to: NSPoint(x: cx, y: cy + 118))
hands.move(to: NSPoint(x: cx, y: cy))
hands.line(to: NSPoint(x: cx + 96, y: cy - 26))
bold.setStroke()
hands.stroke()

// center dot
let dot = NSBezierPath(ovalIn: NSRect(x: cx - 30, y: cy - 30, width: 60, height: 60))
bold.setFill()
dot.fill()

img.unlockFocus()

if let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    print("ok")
}
