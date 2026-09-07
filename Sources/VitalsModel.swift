import SwiftUI
import Combine

final class VitalsModel: ObservableObject {

    // Sistema
    @Published var cpu: Double = 0
    @Published var gpu: Double?
    @Published var memory = MemoryStats(used: 0, total: ProcessInfo.processInfo.physicalMemory)
    @Published var disks: [DiskInfo] = []

    // Claude
    @Published var usage: ClaudeUsageSnapshot?
    @Published var usageError: String?
    @Published var isRefreshing = false
    @Published var lastUpdate: Date?

    private let sampler = CPUSampler()
    private let queue = DispatchQueue(label: "cl.makana.vitals.metrics", qos: .utility)
    private var systemTimer: Timer?
    private var usageTimer: Timer?
    private var lastUsageFetch: Date?
    /// Última vez que Claude Code escribió algo. Marca la diferencia entre
    /// "estás trabajando" y "la app está sola en la barra".
    private var lastActivity: Date?
    /// El próximo reinicio de ventana conocido: el único momento en que los
    /// límites bajan sin que haya actividad que lo delate.
    private var pendingReset: Date?
    /// Espera creciente tras un rechazo del servidor. Insistir cada 3 minutos
    /// contra un 429 solo alarga el bloqueo.
    private var backoff: TimeInterval = 0
    private var retryNotBefore: Date?
    private static let usageCacheKey = "lastUsageSnapshot"
    private var lastDiskScan: Date?
    private var isPanelOpen = false

    /// Con el panel cerrado no hay nada en pantalla que dependa de CPU, GPU o
    /// memoria: el ícono de la barra solo muestra la sesión de Claude. Así que
    /// el muestreo de sistema no corre en segundo plano, no baja de frecuencia.
    private let systemInterval: TimeInterval = 3
    private let diskInterval: TimeInterval = 300

    /// La cadencia se adapta a lo que puede haber cambiado, en vez de ser un
    /// intervalo fijo: con el panel abierto lo estás mirando, mientras Claude
    /// escribe el consumo sube, y en silencio lo único que corre es el reloj.
    private let openInterval: TimeInterval = 30
    private let workingInterval: TimeInterval = 60
    private let idleInterval: TimeInterval = 300
    /// Cuánto rato después de la última escritura se sigue contando como
    /// trabajando: un turno largo puede pensar varios minutos sin tocar disco.
    private let workingWindow: TimeInterval = 10 * 60
    /// Cada cuánto se evalúa si toca consultar. No es una consulta: son dos
    /// comparaciones de fechas, con tolerancia para que macOS junte los avisos.
    private let tickInterval: TimeInterval = 15
    /// Piso entre consultas gatilladas por actividad.
    private let activityCooldown: TimeInterval = 30
    private var watcher: ActivityWatcher?

    // MARK: - Ciclo de vida

    func start() {
        restoreUsage()
        // Con un dato reciente en disco no hace falta consultar al arrancar:
        // reiniciar la app varias veces seguidas era lo que gatillaba el 429.
        if elapsed(since: usage?.fetchedAt) > 120 { refreshClaude() }

        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            self?.tickUsage()
        }
        timer.tolerance = tickInterval / 3
        RunLoop.main.add(timer, forMode: .common)
        usageTimer = timer

        watcher = ActivityWatcher { [weak self] in self?.claudeDidWork() }
        watcher?.start()
    }

    /// Claude Code escribió algo: puede haber consumo nuevo. Con un piso entre
    /// consultas, por si el turno escribe muchas veces seguidas.
    private func claudeDidWork() {
        lastActivity = Date()
        guard elapsed(since: lastUsageFetch) > activityCooldown else { return }
        refreshClaude()
    }

    /// Cada cuánto corresponde consultar, según lo que está pasando.
    private var usageInterval: TimeInterval {
        if isPanelOpen { return openInterval }
        if elapsed(since: lastActivity) < workingWindow { return workingInterval }
        return idleInterval
    }

    /// Se llama cada pocos segundos y casi siempre no hace nada.
    private func tickUsage() {
        // Una ventana que acaba de reiniciarse deja el porcentaje al día aunque
        // no haya habido una sola escritura en horas.
        if let pendingReset, Date() >= pendingReset {
            self.pendingReset = nil
            refreshClaude()
            return
        }
        guard elapsed(since: lastUsageFetch) >= usageInterval else { return }
        refreshClaude()
    }

    func setPanelOpen(_ open: Bool) {
        guard isPanelOpen != open else { return }
        isPanelOpen = open

        if open {
            // El muestreo de CPU es diferencial: sin esta lectura de descarte, el
            // primer valor sería el promedio de todo el rato que estuvo cerrado.
            _ = sampler.sample()
            refreshSystem()
            let timer = Timer(timeInterval: systemInterval, repeats: true) { [weak self] _ in
                self?.refreshSystem()
            }
            RunLoop.main.add(timer, forMode: .common)
            systemTimer = timer
            refreshIfStale()
        } else {
            systemTimer?.invalidate()
            systemTimer = nil
        }
    }

    private func elapsed(since date: Date?) -> TimeInterval {
        guard let date else { return .greatestFiniteMagnitude }
        return Date().timeIntervalSince(date)
    }

    /// Al abrir el panel: pone al día lo que ya está viejo.
    func refreshIfStale() {
        if elapsed(since: lastDiskScan) > diskInterval { refreshDisks() }
        // Abrir el panel es la señal más clara de que el número importa ahora:
        // se consulta salvo que la respuesta sea de hace un pestañeo.
        if elapsed(since: lastUsageFetch) > 10 { refreshClaude() }
    }

    // MARK: - Lecturas

    private func refreshSystem() {
        queue.async { [weak self] in
            guard let self else { return }
            let cpu = self.sampler.sample()
            let gpu = SystemMetrics.gpuUtilization()
            let memory = SystemMetrics.memory()
            DispatchQueue.main.async {
                self.cpu = cpu
                self.gpu = gpu
                self.memory = memory
            }
        }
    }

    private func refreshDisks() {
        lastDiskScan = Date()
        queue.async { [weak self] in
            let disks = SystemMetrics.volumes()
            DispatchQueue.main.async { self?.disks = disks }
        }
    }

    func refreshClaude(force: Bool = false) {
        guard !isRefreshing else { return }
        if !force, let retryNotBefore, Date() < retryNotBefore { return }
        isRefreshing = true
        lastUsageFetch = Date()

        Task { [weak self] in
            let result: Result<ClaudeUsageSnapshot, Error>
            do { result = .success(try await ClaudeAPI.fetchUsage()) }
            catch { result = .failure(error) }
            await self?.apply(result)
        }
    }

    @MainActor
    private func apply(_ result: Result<ClaudeUsageSnapshot, Error>) {
        switch result {
        case .success(let snapshot):
            usage = snapshot
            usageError = nil
            backoff = 0
            retryNotBefore = nil
            storeUsage(snapshot)
            lastUpdate = Date()
            pendingReset = nextReset(in: snapshot)
        case .failure(let error):
            usageError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            backoff = backoff == 0 ? 60 : min(backoff * 2, 900)
            var wait = backoff
            if case VitalsError.rateLimited(let retryAfter) = error { wait = max(wait, retryAfter) }
            retryNotBefore = Date().addingTimeInterval(wait)
        }
        isRefreshing = false
    }

    /// El reinicio más cercano de todos los límites, con unos segundos de
    /// gracia para no llegar antes que el servidor.
    private func nextReset(in snapshot: ClaudeUsageSnapshot) -> Date? {
        let buckets = [snapshot.session, snapshot.weekly] + snapshot.scoped.map(Optional.init)
        return buckets.compactMap { $0?.resetsAt }
            .filter { $0 > Date() }
            .min()?
            .addingTimeInterval(5)
    }

    // MARK: - Último dato conocido

    /// El panel no debería quedar vacío mientras el servidor no responde.
    private func restoreUsage() {
        guard let data = UserDefaults.standard.data(forKey: Self.usageCacheKey),
              let snapshot = try? JSONDecoder().decode(ClaudeUsageSnapshot.self, from: data)
        else { return }
        usage = snapshot
        lastUpdate = snapshot.fetchedAt
        pendingReset = nextReset(in: snapshot)
    }

    private func storeUsage(_ snapshot: ClaudeUsageSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.usageCacheKey)
    }
}

// MARK: - Formato

enum Format {
    /// El signo no va pegado en todos los idiomas —el francés lo separa— así
    /// que el porcentaje lo arma el sistema, no una interpolación.
    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp
        return formatter
    }()

    static func percent(_ value: Double) -> String {
        percentFormatter.string(from: NSNumber(value: value)) ?? "\(Int((value * 100).rounded()))%"
    }

    static func bytes(_ value: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useTB, .useMB]
        return formatter.string(fromByteCount: Int64(value))
    }


    /// Tamaños cortos: "886 GB", "16,2 GB", "1,02 TB".
    static func bytesShort(_ value: UInt64) -> String {
        let gb = Double(value) / 1_000_000_000
        if gb >= 1_000 { return String(format: "%.2f TB", locale: .current, gb / 1_000) }
        if gb >= 100 { return String(format: "%.0f GB", locale: .current, gb) }
        if gb >= 1 { return String(format: "%.1f GB", locale: .current, gb) }
        return String(format: "%.0f MB", locale: .current, Double(value) / 1_000_000)
    }

    /// "52 min" / "4 d 5 h"
    static func countdown(to date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        guard seconds > 0 else { return L10n.countdownNow }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return L10n.countdownDays(days, hours) }
        if hours > 0 { return L10n.countdownHours(hours, minutes) }
        return L10n.countdownMinutes(minutes)
    }
}

extension Color {
    /// El color de acento que el usuario eligió en Ajustes del Sistema.
    static let systemAccent = Color(nsColor: .controlAccentColor)

    /// El coral de Claude.
    static let claude = Color(red: 0.851, green: 0.467, blue: 0.341)
}

extension Double {
    /// Color propio de la sección; ámbar y rojo solo cuando de verdad importa.
    func meterColor(_ base: Color) -> Color {
        switch self {
        case 0.9...: return .red
        case 0.75..<0.9: return .orange
        default: return base
        }
    }
}
