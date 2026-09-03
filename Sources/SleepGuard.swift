import Foundation
import IOKit.pwr_mgt
import Combine

/// Impide que el Mac se duerma sin impedir que la pantalla se apague. Es la
/// diferencia que importa cuando dejas agentes o shells corriendo: la pantalla
/// negra no detiene nada, dormir el sistema sí.
final class SleepGuard: ObservableObject {
    @Published private(set) var isActive = false

    private var assertion: IOPMAssertionID = IOPMAssertionID(0)

    func toggle() {
        isActive ? disable() : enable()
    }

    func enable() {
        guard !isActive else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Vitals: trabajo en curso" as CFString,
            &id)
        guard result == kIOReturnSuccess else { return }
        assertion = id
        isActive = true
    }

    func disable() {
        guard isActive else { return }
        IOPMAssertionRelease(assertion)
        assertion = IOPMAssertionID(0)
        isActive = false
    }

    /// Apaga la pantalla ahora mismo. No necesita privilegios.
    func sleepDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    /// El caso de uso completo: te vas, la pantalla se apaga, el trabajo sigue.
    func workWithScreenOff() {
        enable()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.sleepDisplay()
        }
    }
}
