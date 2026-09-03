import AppKit

/// El ícono de la barra, dibujado como imagen *template*: macOS la pinta con el
/// color de la barra de menús (negro sobre claro, blanco sobre oscuro) y le
/// aplica el mismo tratamiento que a Wi-Fi o batería, así que se ve parejo
/// sobre cualquier fondo de pantalla. Las alfas relativas se conservan, que es
/// lo que permite un riel tenue y un relleno sólido en la misma imagen.
enum StatusIcon {
    static let size = NSSize(width: 17, height: 17)

    /// - Parameters:
    ///   - used: cuánto se lleva consumido de la sesión, 0…1. `nil` dibuja solo
    ///           el riel. Se dibuja lo consumido y no lo restante porque el uso
    ///           típico es bajo: a 1% gastado, un anillo de "lo que queda"
    ///           saldría 99% completo, indistinguible de un círculo lleno.
    ///   - alert: color fijo cuando queda poco. Rompe el modo template a
    ///            propósito, igual que la batería en rojo.
    static func make(used: Double?, alert: NSColor?) -> NSImage {
        let lineWidth: CGFloat = 2.4
        let inset: CGFloat = 1.6

        let image = NSImage(size: size, flipped: false) { rect in
            let radius = rect.width / 2 - inset - lineWidth / 2
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let color = alert ?? .black

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            color.withAlphaComponent(0.30).setStroke()
            track.stroke()

            if let used, used > 0 {
                // Piso de 10°: un 1% igual tiene que dejar una marca visible.
                let sweep = max(360 * min(used, 1), 10)
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center,
                              radius: radius,
                              startAngle: 90,
                              endAngle: 90 - sweep,
                              clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
            return true
        }

        image.isTemplate = (alert == nil)
        return image
    }

    /// Naranjo sobre 80% consumido, rojo sobre 90%.
    static func alertColor(for used: Double?) -> NSColor? {
        guard let used else { return nil }
        if used >= 0.90 { return .systemRed }
        if used >= 0.80 { return .systemOrange }
        return nil
    }
}
