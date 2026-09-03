import AppKit
import SwiftUI
import ServiceManagement
import Combine

/// Ventana sin borde con el mismo material que los menús del sistema. Un
/// NSPopover se ve distinto de los paneles de Wi-Fi o batería: tiene flecha y
/// otra vibrancia, así que acá se arma a mano.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    let effect = NSVisualEffectView()

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 304, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor

        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor)
        ])
        contentView = effect
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = VitalsModel()
    private let sleepGuard = SleepGuard()
    private let keyboardLock = KeyboardLock()
    private var statusItem: NSStatusItem!
    private var panel: PanelWindow!
    private var controller: NSHostingController<PanelView>!
    private var sizeObservation: NSKeyValueObservation?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        registerLoginItemIfNeeded()
        buildStatusItem()
        buildPanel()
    }

    // MARK: - Barra de menús

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        updateStatusIcon()
        model.$usage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let session = model.usage?.session
        let used = session.map { min(max($0.fraction, 0), 1) }
        let alert = StatusIcon.alertColor(for: used)

        button.image = StatusIcon.make(used: used, alert: alert)
        button.contentTintColor = alert

        if UserDefaults.standard.bool(forKey: "showSessionPercent") {
            button.title = used.map { " " + Format.percent($0) } ?? " —"
        } else {
            button.title = ""
        }

        if let session, let used {
            var tip = L10n.menuBarTooltip(used: Format.percent(used), left: Format.percent(1 - used))
            if let resetsAt = session.resetsAt {
                tip += L10n.menuBarTooltipResets(Format.countdown(to: resetsAt))
            }
            button.toolTip = tip
        } else {
            button.toolTip = L10n.menuBarNoData
        }
    }

    // MARK: - Panel

    private func buildPanel() {
        controller = NSHostingController(rootView: PanelView(model: model,
                                                             sleepGuard: sleepGuard,
                                                             keyboardLock: keyboardLock,
                                                             dismiss: { [weak self] in self?.hidePanel() }))
        controller.sizingOptions = [.preferredContentSize]
        panel = PanelWindow(content: controller.view)

        sizeObservation = controller.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let size = change.newValue, size.height > 1 else { return }
            self?.resize(to: size)
        }

        // El monitor de clics no alcanza a ver todo: el reloj, el Centro de
        // Control y los demás íconos de la barra se tragan el clic en su propio
        // bucle de seguimiento, y un Cmd-Tab no es un clic. Lo que sí ocurre en
        // todos esos casos es que el panel deja de ser la ventana con foco.
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: panel)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.hideIfFocusLeft() }
            .store(in: &cancellables)
    }

    /// El menú del engranaje también le saca el foco al panel, y ahí no hay
    /// nada que cerrar: el foco sigue en una ventana propia. Un paso por el
    /// runloop para que esa ventana alcance a tomarlo.
    private func hideIfFocusLeft() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible, !self.panel.isKeyWindow,
                  !NSApp.windows.contains(where: { $0.isKeyWindow })
            else { return }
            self.hidePanel()
        }
    }

    /// El panel crece hacia abajo, con el borde superior clavado bajo la barra.
    private func resize(to size: NSSize) {
        guard panel.frame.size != size else { return }
        let top = panel.frame.maxY
        let frame = NSRect(x: panel.frame.minX, y: top - size.height, width: size.width, height: size.height)

        guard panel.isVisible else { panel.setFrame(frame, display: false); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    @objc private func togglePanel() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showContextMenu()
            return
        }
        panel.isVisible ? hidePanel() : showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button, let barWindow = button.window else { return }
        model.setPanelOpen(true)

        let size = controller.view.fittingSize
        let anchor = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)

        if let visible = (barWindow.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
        startMonitors()
    }

    private func hidePanel() {
        guard panel.isVisible else { return }
        stopMonitors()
        model.setPanelOpen(false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        }
    }

    // MARK: - Cierre al clicar fuera

    private func startMonitors() {
        stopMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.hidePanel(); return nil }
                return event
            }
            // El clic sobre el propio ícono lo maneja su acción, no el monitor.
            if event.window !== self.panel && event.window !== self.statusItem.button?.window {
                self.hidePanel()
            }
            return event
        }
    }

    private func stopMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    // MARK: - Menú contextual

    private func showContextMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: L10n.actionRefresh, action: #selector(refresh), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L10n.actionQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refresh() {
        model.refreshClaude()
    }

    // MARK: - Inicio de sesión

    /// Se registra una sola vez. Si después lo apagas desde el engranaje, no se
    /// vuelve a prender solo.
    private func registerLoginItemIfNeeded() {
        let key = "didRegisterLoginItem"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        try? SMAppService.mainApp.register()
    }
}

// Salida de diagnóstico del idioma, antes de levantar nada de interfaz.
if CommandLine.arguments.contains("--dump-strings") {
    L10n.dump()
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
