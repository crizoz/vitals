import AppKit
import SwiftUI
import Combine

/// Bloquea el teclado para poder limpiarlo. El trackpad queda libre a propósito:
/// el tap de eventos solo intercepta teclas.
final class KeyboardLock: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var secondsLeft = 0
    /// Sin permiso de Accesibilidad no se pueden atajar los atajos del sistema.
    @Published private(set) var isPartial = false

    private var window: NSWindow?
    private var timer: Timer?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    func start(seconds: Int = 30) {
        guard !isLocked else { return }
        isLocked = true
        secondsLeft = seconds
        isPartial = !startEventTap()
        showOverlay()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.secondsLeft -= 1
            if self.secondsLeft <= 0 { self.stop() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard isLocked else { return }
        timer?.invalidate()
        timer = nil
        stopEventTap()
        window?.orderOut(nil)
        window = nil
        isLocked = false
        secondsLeft = 0
    }

    func extend(by seconds: Int = 30) {
        guard isLocked else { return }
        secondsLeft += seconds
    }

    // MARK: - Intercepción de teclas

    /// Tipos que no son casos de `CGEventType`: hay que compararlos crudos.
    private static let systemDefined: UInt32 = 14        // NX_SYSDEFINED
    private static let auxButtons: Int16 = 8             // NX_SUBTYPE_AUX_CONTROL_BUTTONS

    /// Traga teclas a nivel de sesión. Requiere Accesibilidad; si no está, la
    /// ventana en primer plano igual absorbe lo que se escribe.
    ///
    /// La fila de arriba —brillo, volumen, reproducción, Mission Control— no
    /// viaja como tecla: sale como evento de sistema (tipo 14, subtipo 8), que
    /// no entra por keyDown. Sin atajarlo, pasar el paño por las F cambia el
    /// brillo igual. Fn y Bloq Mayús las resuelve el teclado antes del tap: esas
    /// no hay cómo atajarlas.
    private func startEventTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << KeyboardLock.systemDefined)

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask),
                                          callback: { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let lock = Unmanaged<KeyboardLock>.fromOpaque(userInfo).takeUnretainedValue()

            // El sistema apaga el tap si tarda en responder; hay que revivirlo o
            // el bloqueo queda de adorno.
            if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue
                || type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
                lock.enableTap()
                return nil
            }

            // De los eventos de sistema solo interesan los botones auxiliares:
            // los demás subtipos son cosas del mouse y se dejan pasar.
            if type.rawValue == KeyboardLock.systemDefined {
                guard let nsEvent = NSEvent(cgEvent: event),
                      nsEvent.type == .systemDefined,
                      nsEvent.subtype.rawValue == KeyboardLock.auxButtons
                else { return Unmanaged.passUnretained(event) }
            }

            return nil
        },
                                          userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    fileprivate func enableTap() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopEventTap() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    // MARK: - Cubierta

    private func showOverlay() {
        let frame = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        let window = LockWindow(contentRect: frame,
                                styleMask: [.borderless],
                                backing: .buffered,
                                defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false

        let hosting = NSHostingView(rootView: KeyboardLockView(lock: self))
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}

/// Ventana que se queda con el foco de teclado y descarta todo lo que llega.
private final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}

private struct KeyboardLockView: View {
    @ObservedObject var lock: KeyboardLock

    var body: some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.82))

            VStack(spacing: 20) {
                Image(systemName: "keyboard")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.white)

                Text(L10n.lockTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                Text(L10n.lockSeconds(lock.secondsLeft))
                    .font(.system(size: 64, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.2), value: lock.secondsLeft)
                    .foregroundStyle(.white)

                Text(lock.isPartial ? L10n.lockNotePartial : L10n.lockNoteFull)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: 380)

                HStack(spacing: 12) {
                    Button(L10n.lockExtend) { lock.extend() }
                    Button(L10n.lockFinish) { lock.stop() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
        }
        .ignoresSafeArea()
    }
}
