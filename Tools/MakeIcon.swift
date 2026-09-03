import AppKit

// Genera Resources/Vitals.icns. El motivo es el mismo anillo de la barra de
// menús, para que el ícono y lo que ves a diario sean la misma cosa.

let coral = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
let coralLight = NSColor(srgbRed: 0.933, green: 0.596, blue: 0.478, alpha: 1)

/// Superelipse: la curva continua de los íconos de Apple. Un rectángulo
/// redondeado corriente se nota más anguloso al llegar a las esquinas.
func squircle(in rect: NSRect, n: Double = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY

    for step in 0...720 {
        let t = Double(step) / 720 * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = pow(abs(cosT), 2 / n) * a * (cosT < 0 ? -1 : 1)
        let y = pow(abs(sinT), 2 / n) * b * (sinT < 0 ? -1 : 1)
        let point = NSPoint(x: cx + x, y: cy + y)
        step == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

/// Rellena el trazo de un camino con un degradado. CoreGraphics no sabe teñir
/// un trazo, así que se convierte el trazo en región y se recorta contra ella.
func strokeGradient(_ path: NSBezierPath, width: CGFloat, cap: CGLineCap,
                    from top: NSColor, to bottom: NSColor, in rect: NSRect) {
    guard let cg = NSGraphicsContext.current?.cgContext else { return }
    cg.saveGState()
    cg.setLineWidth(width)
    cg.setLineCap(cap)
    cg.addPath(path.cgPath)
    cg.replacePathWithStrokedPath()
    cg.clip()
    NSGradient(colors: [top, bottom])?.draw(in: rect, angle: -90)
    cg.restoreGState()
}

func draw(size: CGFloat) {
    guard let context = NSGraphicsContext.current else { return }
    context.imageInterpolation = .high

    // El arte no llena el lienzo: macOS espera aire alrededor para la sombra.
    let inset = size * 0.085
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = squircle(in: body)
    let center = NSPoint(x: body.midX, y: body.midY)

    // Sombra proyectada.
    context.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = size * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.014)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    context.restoreGraphicsState()

    // Cuerpo: grafito más claro arriba, como una superficie iluminada de frente.
    context.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.271, green: 0.282, blue: 0.310, alpha: 1),
                        NSColor(srgbRed: 0.094, green: 0.098, blue: 0.114, alpha: 1)])?
        .draw(in: body, angle: -90)

    // Resplandor cálido detrás del anillo, para que el coral no quede pegado
    // sobre un fondo plano.
    NSGradient(starting: coral.withAlphaComponent(0.13), ending: coral.withAlphaComponent(0))?
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: body.width * 0.46, options: [])
    context.restoreGraphicsState()

    // Anillo.
    let radius = body.width * 0.255
    let lineWidth = body.width * 0.090
    let ringRect = NSRect(x: center.x - radius - lineWidth, y: center.y - radius - lineWidth,
                          width: (radius + lineWidth) * 2, height: (radius + lineWidth) * 2)

    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = lineWidth
    coral.withAlphaComponent(0.18).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius,
                  startAngle: 90, endAngle: 90 - 278, clockwise: true)
    strokeGradient(arc, width: lineWidth, cap: .round,
                   from: coralLight, to: coral, in: ringRect)

    // Filo claro en el borde superior: lo que separa el ícono del fondo.
    context.saveGraphicsState()
    shape.addClip()
    let rim = squircle(in: body.insetBy(dx: size * 0.005, dy: size * 0.005))
    strokeGradient(rim, width: size * 0.011, cap: .round,
                   from: NSColor(white: 1, alpha: 0.34),
                   to: NSColor(white: 1, alpha: 0.02), in: body)
    context.restoreGraphicsState()
}

/// Un NSImage con lockFocus se dibuja al doble en pantallas Retina. Para que
/// cada archivo tenga los píxeles exactos que pide el iconset, se dibuja en un
/// bitmap del tamaño declarado.
func render(size: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: size, pixelsHigh: size,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw(size: CGFloat(size))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/Vitals.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, size) in variants {
    guard let png = render(size: size) else { continue }
    try! png.write(to: iconset.appendingPathComponent("\(name).png"))
}
print("iconset listo")
