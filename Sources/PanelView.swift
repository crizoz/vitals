import SwiftUI
import ServiceManagement

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var model: VitalsModel
    @ObservedObject var sleepGuard: SleepGuard
    @ObservedObject var keyboardLock: KeyboardLock
    /// Cierra el panel antes de una acción que se toma la pantalla.
    var dismiss: () -> Void = {}

    @AppStorage("section.system") private var showSystem = true
    @AppStorage("section.storage") private var showStorage = true
    @AppStorage("section.claude") private var showClaude = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Section(title: "Sistema", symbol: "cpu", accent: .systemAccent,
                    isExpanded: $showSystem, summary: systemSummary) {
                HStack(spacing: 0) {
                    Gauge(title: "CPU", fraction: model.cpu, text: Format.percent(model.cpu))
                    Gauge(title: "GPU", fraction: model.gpu ?? 0,
                          text: model.gpu.map(Format.percent) ?? "—")
                    Gauge(title: "Memoria", fraction: model.memory.fraction,
                          reclaimable: model.memory.cachedFraction,
                          text: Format.percent(model.memory.fraction))
                }
                .padding(.top, 2)
            }

            separator

            Section(title: "Almacenamiento", symbol: "internaldrive", accent: .systemAccent,
                    isExpanded: $showStorage, summary: storageSummary) {
                if model.disks.isEmpty {
                    Placeholder("Leyendo volúmenes…")
                } else {
                    ForEach(model.disks) { disk in
                        Meter(title: disk.name,
                              note: Format.percent(disk.fraction),
                              value: "\(Format.bytesShort(disk.free)) libres",
                              fraction: disk.fraction,
                              accent: .systemAccent,
                              help: "\(disk.isInternal ? "Interno" : "Externo") · \(Format.bytes(disk.used)) usados de \(Format.bytes(disk.total))")
                    }
                }
            }

            separator

            Section(title: "Claude", symbol: "sparkle", accent: .claude,
                    isExpanded: $showClaude, summary: claudeSummary) {
                claudeContent
            }

            Divider().padding(.top, 14)
            actions
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(width: 304)
        // El panel no activa la app a propósito, para no sacarle el foco a lo
        // que estés usando. Sin esto, los controles del sistema se dibujarían
        // apagados y las barras perderían el color.
        .environment(\.controlActiveState, .key)
        .animation(.smooth(duration: 0.3), value: model.usage)
        .animation(.smooth(duration: 0.3), value: model.usageError)
        .animation(.smooth(duration: 0.3), value: model.disks)
    }

    private var separator: some View {
        Divider().padding(.vertical, 12)
    }

    // MARK: Claude

    @ViewBuilder
    private var claudeContent: some View {
        if let usage = model.usage {
            if let session = usage.session { LimitMeter(bucket: session) }
            if let weekly = usage.weekly { LimitMeter(bucket: weekly) }
            ForEach(usage.scoped) { LimitMeter(bucket: $0) }
        } else if model.usageError == nil {
            Placeholder("Consultando límites…")
        }

        // El aviso va al final: si hay datos previos siguen a la vista.
        if let error = model.usageError {
            Placeholder(error, symbol: "exclamationmark.triangle")
        }
    }

    // MARK: Resúmenes al colapsar

    private var systemSummary: String {
        "\(Format.percent(model.cpu)) · \(model.gpu.map(Format.percent) ?? "—") · \(Format.percent(model.memory.fraction))"
    }

    private var storageSummary: String {
        guard let boot = model.disks.first else { return "—" }
        return "\(Format.bytes(boot.free)) libres"
    }

    private var claudeSummary: String {
        guard let usage = model.usage else { return model.usageError ?? "—" }
        let session = usage.session.map { Format.percent($0.fraction) } ?? "—"
        let weekly = usage.weekly.map { Format.percent($0.fraction) } ?? "—"
        return "\(session) · \(weekly)"
    }

    // MARK: Acciones

    private var actions: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)

            CircleAction(symbol: "keyboard",
                         help: "Bloquea las teclas 30 s para limpiarlas. El trackpad sigue libre.") {
                dismiss()
                keyboardLock.start()
            }

            CircleAction(symbol: "cup.and.saucer.fill",
                         help: sleepGuard.isActive
                            ? "El Mac no se dormirá. Toca para apagarlo."
                            : "Evita que el Mac se duerma. La pantalla igual puede apagarse.",
                         isOn: sleepGuard.isActive) {
                sleepGuard.toggle()
            }

            CircleAction(symbol: "moon.fill",
                         help: "Apaga la pantalla y deja el Mac despierto para que siga trabajando.") {
                dismiss()
                sleepGuard.workWithScreenOff()
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 12)
    }

    // MARK: Pie

    private var footer: some View {
        // Agrupados y centrados, sobre el mismo eje que la fila de botones. Con
        // un Spacer entremedio quedaban clavados en los extremos opuestos.
        HStack(spacing: 6) {
            Text(freshness)
                .font(.caption)
                .foregroundStyle(.tertiary)
            SettingsMenu(refresh: { model.refreshClaude(force: true) })
        }
        .frame(height: 22)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    /// Más legible que una hora exacta: lo que importa es si el dato está fresco.
    private var freshness: String {
        guard let last = model.lastUpdate else { return "" }
        let seconds = Int(Date().timeIntervalSince(last))
        switch seconds {
        case ..<90: return "Actualizado recién"
        case ..<3_600: return "Actualizado hace \(seconds / 60) min"
        default: return "Actualizado hace \(seconds / 3_600) h"
        }
    }
}

// MARK: - Sección colapsable

private struct Section<Content: View>: View {
    let title: String
    let symbol: String
    let accent: Color
    @Binding var isExpanded: Bool
    var summary: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.26)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 9)
                    Image(systemName: symbol)
                        .imageScale(.small)
                        .foregroundStyle(accent)
                        .frame(width: 15)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if !isExpanded {
                        Text(summary)
                            .font(.subheadline)
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .transition(.opacity)
                            .animation(.easeOut(duration: 0.25), value: summary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) { content }
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),
                        removal: .opacity.animation(.easeIn(duration: 0.12))))
            }
        }
    }
}

// MARK: - Medidor semicircular

/// Arco de 180° para CPU, GPU y memoria: lecturas instantáneas, a diferencia de
/// las barras, que miden capacidad ocupada.
private struct ArcShape: Shape {
    var from: Double = 0
    var to: Double
    var lineWidth: CGFloat

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(from, to) }
        set { from = newValue.first; to = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let start = 180 + 180 * min(max(from, 0), 1)
        let end = 180 + 180 * min(max(to, 0), 1)
        guard end - start > 0.01 else { return Path() }

        let radius = max(1, min(rect.width / 2, rect.height) - lineWidth / 2)
        let center = CGPoint(x: rect.midX, y: rect.maxY - lineWidth / 2)
        var path = Path()
        path.addArc(center: center,
                    radius: radius,
                    startAngle: .degrees(start),
                    endAngle: .degrees(end),
                    clockwise: false)
        return path
    }
}

private struct Gauge: View {
    let title: String
    let fraction: Double
    /// Tramo neutro que continúa al principal: memoria reclamable, no ocupada.
    var reclaimable: Double = 0
    let text: String

    private let lineWidth: CGFloat = 6

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                ArcShape(to: 1, lineWidth: lineWidth)
                    .stroke(Color(nsColor: .quaternaryLabelColor),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                if reclaimable > 0.005 {
                    ArcShape(from: fraction, to: fraction + reclaimable, lineWidth: lineWidth)
                        .stroke(Color(nsColor: .secondaryLabelColor),
                                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .animation(.easeOut(duration: 0.45), value: fraction + reclaimable)
                }
                ArcShape(to: fraction, lineWidth: lineWidth)
                    .stroke(fraction.meterColor(.systemAccent),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .animation(.easeOut(duration: 0.45), value: fraction)
                Text(text)
                    .font(.body.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: text)
                    .offset(y: 8)
            }
            .frame(height: 38)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Barra

private struct Meter: View {
    let title: String
    var note: String? = nil
    let value: String
    let fraction: Double
    var accent: Color = .systemAccent
    /// Proporción de la ventana ya transcurrida, dibujada como marca sobre la barra.
    var pace: Double? = nil
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let note {
                    Text(note)
                        .font(.caption)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.easeOut(duration: 0.3), value: note)
                        .foregroundStyle(.tertiary)
                }
                Text(value)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: value)
                    .foregroundStyle(.secondary)
            }
            .font(.body)

            Track(fraction: fraction, color: fraction.meterColor(accent), pace: pace)
        }
        .help(help ?? "")
    }
}

/// Barra propia en vez de ProgressView. El panel no activa la app —para no
/// robarle el foco a lo que estés usando— y en ese estado macOS dibuja sus
/// controles desaturados: el coral se perdía. Mismo grosor y forma que la
/// barra del sistema, pero con el color bajo control.
private struct Track: View {
    let fraction: Double
    let color: Color
    /// Proporción de la ventana ya transcurrida, como marca vertical.
    var pace: Double? = nil

    private let height: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor))
                Capsule()
                    .fill(color)
                    .frame(width: max(height, proxy.size.width * clamp(fraction)))
                if let pace {
                    Capsule()
                        .fill(Color(nsColor: .labelColor).opacity(0.55))
                        .frame(width: 2, height: 9)
                        .offset(x: min(max(proxy.size.width * clamp(pace) - 1, 0),
                                       proxy.size.width - 2))
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.4), value: fraction)
        .animation(.easeOut(duration: 0.4), value: pace)
    }

    private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

private struct LimitMeter: View {
    let bucket: LimitBucket

    var body: some View {
        Meter(title: bucket.title,
              note: bucket.resetsAt.map { Format.countdown(to: $0) },
              value: Format.percent(bucket.fraction),
              fraction: bucket.fraction,
              accent: .claude,
              pace: bucket.elapsed,
              help: help)
    }

    private var help: String {
        guard let resetsAt = bucket.resetsAt else { return "\(Format.percent(bucket.fraction)) usado" }
        var text = "\(Format.percent(bucket.fraction)) usado · se reinicia en \(Format.countdown(to: resetsAt))"
        if let elapsed = bucket.elapsed {
            text += "\nLa marca es el \(Format.percent(elapsed)) de la ventana ya transcurrido"
        }
        return text
    }
}

// MARK: - Auxiliares

private struct Caption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .contentTransition(.numericText())
            .animation(.easeOut(duration: 0.3), value: text)
    }
}

private struct Placeholder: View {
    let text: String
    var symbol: String? = nil

    init(_ text: String, symbol: String? = nil) {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small)
            }
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .transition(.opacity)
    }
}

/// Botón redondo al estilo del Centro de Control: relleno translúcido, filo
/// claro arriba que sugiere relieve, y hundido al presionar.
private struct CircleAction: View {
    let symbol: String
    let help: String
    var isOn: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
        }
        .buttonStyle(CircleActionStyle(isOn: isOn, isHovering: isHovering))
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct CircleActionStyle: ButtonStyle {
    let isOn: Bool
    let isHovering: Bool

    private let diameter: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .frame(width: diameter, height: diameter)
            .background {
                Circle()
                    .fill(fill)
                    .overlay {
                        // Filo más claro arriba que abajo: es lo que da la
                        // sensación de volumen en los controles de macOS.
                        Circle().strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(isOn ? 0.35 : 0.22),
                                                    Color.white.opacity(0.03)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.8)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            }
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isOn)
            .animation(.easeOut(duration: 0.15), value: isHovering)
    }

    private var fill: AnyShapeStyle {
        if isOn { return AnyShapeStyle(Color.systemAccent) }
        return AnyShapeStyle(Color.primary.opacity(isHovering ? 0.16 : 0.10))
    }
}

private struct SettingsMenu: View {
    let refresh: () -> Void

    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("showSessionPercent") private var showPercent = false

    var body: some View {
        Menu {
            Button("Actualizar ahora", action: refresh)
            Divider()
            Toggle("Mostrar porcentaje en la barra", isOn: $showPercent)
            Toggle("Abrir al iniciar sesión", isOn: $launchesAtLogin)
                .onChange(of: launchesAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchesAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Divider()
            Button("Salir de Vitals") { NSApplication.shared.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
                .imageScale(.small)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 20)
    }
}
