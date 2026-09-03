import Foundation
import Security

// MARK: - Modelos

struct LimitBucket: Identifiable, Hashable, Codable {
    /// Qué límite es. Se guarda el tipo y no el rótulo ya traducido: el último
    /// dato conocido sobrevive en disco entre arranques, y con el texto adentro
    /// habría quedado en el idioma de la sesión que lo escribió.
    enum Kind: String, Codable {
        case session, weekly, model
    }

    let id: String
    let kind: Kind
    /// Solo para `.model`: el nombre que manda el servidor, que no se traduce.
    let name: String?
    let fraction: Double
    let resetsAt: Date?
    /// Largo total de la ventana: 5 h para la sesión, 7 días para las semanales.
    let window: TimeInterval?
    let severity: String

    var title: String {
        switch kind {
        case .session: return L10n.claudeSession
        case .weekly: return L10n.claudeWeekly
        case .model: return name ?? L10n.claudeModel
        }
    }

    static let sessionWindow: TimeInterval = 5 * 3_600
    static let weeklyWindow: TimeInterval = 7 * 86_400

    /// Qué proporción de la ventana ya transcurrió. Puesta sobre la barra deja
    /// ver de una si el consumo va adelantado o atrasado respecto del reloj.
    var elapsed: Double? {
        guard let resetsAt, let window, window > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSinceNow
        return min(1, max(0, 1 - remaining / window))
    }
}

struct ClaudeUsageSnapshot: Equatable, Codable {
    var session: LimitBucket?
    var weekly: LimitBucket?
    var scoped: [LimitBucket] = []
    var plan: String?
    var fetchedAt = Date()
}

enum VitalsError: LocalizedError {
    case noCredentials
    case keychain(OSStatus)
    case rateLimited(retryAfter: TimeInterval)
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return L10n.errorNoCredentials
        case .keychain(errSecUserCanceled), .keychain(errSecAuthFailed), .keychain(errSecInteractionNotAllowed):
            return L10n.errorKeychainAccess
        case .keychain(let status):
            return L10n.errorKeychain(status)
        case .rateLimited:
            return L10n.errorRateLimited
        case .badStatus(401), .badStatus(403):
            return L10n.errorExpired
        case .badStatus(let code):
            return L10n.errorStatus(code)
        }
    }
}

// MARK: - Credenciales

enum ClaudeCredentials {
    /// El ítem del llavero donde Claude Code deja el token OAuth.
    private static let service = "Claude Code-credentials"

    /// El ítem lo escribe Claude Code con `/usr/bin/security`, así que su ACL
    /// confía en esa herramienta y su lista de particiones queda en
    /// `apple-tool:` —la que cubre a las herramientas firmadas por Apple—. Cada
    /// vez que el CLI rota el token vuelve a escribirlo y la lista se resetea,
    /// de modo que cualquier otra app queda fuera y macOS pide la contraseña
    /// del llavero otra vez. Autorizar "Permitir siempre" no alcanza: agrega a
    /// Vitals a la lista de apps confiables, pero no a la partición, y el
    /// siguiente refresco del token deshace el permiso.
    ///
    /// Por eso se lee a través de `security`, igual que hace Claude Code: el
    /// que pide el secreto es una herramienta que el ítem ya autoriza, y no hay
    /// diálogo. Si por lo que sea no está disponible, se cae al acceso directo
    /// de siempre.
    private static let securityTool = "/usr/bin/security"

    private static let lock = NSLock()
    private static var cached: (token: String, validUntil: Date)?

    /// Vale entre lecturas mientras el token siga vigente. El margen deja
    /// afuera el borde en que el CLI ya lo rotó pero el reloj aún no lo dice.
    private static let expiryMargin: TimeInterval = 120
    /// Si el JSON no trae vencimiento, se releé cada tanto por las dudas.
    private static let fallbackTTL: TimeInterval = 300

    /// Descarta el token guardado: se llama cuando el servidor lo rechaza, para
    /// que el próximo intento vaya al llavero en vez de reusar uno vencido.
    static func invalidate() {
        lock.lock(); defer { lock.unlock() }
        cached = nil
    }

    static func accessToken() throws -> String {
        lock.lock()
        if let cached, cached.validUntil > Date() {
            defer { lock.unlock() }
            return cached.token
        }
        lock.unlock()

        let data = try readItem()
        let (token, expiresAt) = try parse(data)

        lock.lock()
        cached = (token, expiresAt ?? Date().addingTimeInterval(fallbackTTL))
        lock.unlock()
        return token
    }

    private static func parse(_ data: Data) throws -> (String, Date?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { throw VitalsError.noCredentials }

        // `expiresAt` viene en milisegundos desde epoch.
        var expiry: Date?
        if let millis = (oauth["expiresAt"] as? NSNumber)?.doubleValue, millis > 0 {
            let date = Date(timeIntervalSince1970: millis / 1000).addingTimeInterval(-expiryMargin)
            if date > Date() { expiry = date }
        }
        return (token, expiry)
    }

    private static func readItem() throws -> Data {
        do { return try readViaSecurityTool() }
        catch VitalsError.noCredentials { throw VitalsError.noCredentials }
        catch { return try readViaKeychainAPI() }
    }

    /// `security find-generic-password -w` escribe el secreto en stdout y nada
    /// más. Sale 44 cuando el ítem no existe.
    private static func readViaSecurityTool() throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: securityTool) else {
            throw VitalsError.keychain(errSecInternalError)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityTool)
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { throw VitalsError.keychain(errSecInternalError) }

        // Un llavero bloqueado dejaría al CLI esperando una respuesta que nadie
        // va a dar: se corta y se sigue por el otro camino.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        if process.terminationStatus == 44 { throw VitalsError.noCredentials }
        guard process.terminationStatus == 0, !data.isEmpty else {
            throw VitalsError.keychain(errSecInternalError)
        }
        return data
    }

    /// El camino de siempre. Puede abrir el diálogo del llavero, así que queda
    /// solo como respaldo.
    private static func readViaKeychainAPI() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { throw VitalsError.noCredentials }
        guard status == errSecSuccess, let data = item as? Data else {
            FileHandle.standardError.write(Data("keychain OSStatus \(status)\n".utf8))
            throw VitalsError.keychain(status)
        }
        return data
    }
}

// MARK: - API

enum ClaudeAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func fetchUsage() async throws -> ClaudeUsageSnapshot {
        let token = try ClaudeCredentials.accessToken()

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw VitalsError.badStatus(0) }

        if http.statusCode == 429 {
            let header = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init) ?? 0
            throw VitalsError.rateLimited(retryAfter: header)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            // El CLI ya rotó el token: el guardado no sirve más.
            ClaudeCredentials.invalidate()
        }
        guard http.statusCode == 200 else { throw VitalsError.badStatus(http.statusCode) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VitalsError.badStatus(200)
        }
        return parse(json)
    }

    private static func parse(_ json: [String: Any]) -> ClaudeUsageSnapshot {
        var snapshot = ClaudeUsageSnapshot()

        for raw in json["limits"] as? [[String: Any]] ?? [] {
            let kind = raw["kind"] as? String ?? ""
            let percent = (raw["percent"] as? NSNumber)?.doubleValue ?? 0
            let severity = raw["severity"] as? String ?? "normal"
            let reset = date(from: raw["resets_at"] as? String)

            switch kind {
            case "session":
                snapshot.session = LimitBucket(id: "session", kind: .session, name: nil,
                                               fraction: percent / 100, resetsAt: reset,
                                               window: LimitBucket.sessionWindow, severity: severity)
            case "weekly_all":
                snapshot.weekly = LimitBucket(id: "weekly", kind: .weekly, name: nil,
                                              fraction: percent / 100, resetsAt: reset,
                                              window: LimitBucket.weeklyWindow, severity: severity)
            case "weekly_scoped":
                let scope = raw["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = model?["display_name"] as? String
                snapshot.scoped.append(LimitBucket(id: "weekly_\(name ?? "model")", kind: .model, name: name,
                                                   fraction: percent / 100, resetsAt: reset,
                                                   window: LimitBucket.weeklyWindow, severity: severity))
            default:
                break
            }
        }

        // Respaldo si el arreglo `limits` no viniera.
        if snapshot.session == nil, let bucket = json["five_hour"] as? [String: Any] {
            snapshot.session = LimitBucket(id: "session", kind: .session, name: nil,
                                           fraction: ((bucket["utilization"] as? NSNumber)?.doubleValue ?? 0) / 100,
                                           resetsAt: date(from: bucket["resets_at"] as? String),
                                           window: LimitBucket.sessionWindow, severity: "normal")
        }
        if snapshot.weekly == nil, let bucket = json["seven_day"] as? [String: Any] {
            snapshot.weekly = LimitBucket(id: "weekly", kind: .weekly, name: nil,
                                          fraction: ((bucket["utilization"] as? NSNumber)?.doubleValue ?? 0) / 100,
                                          resetsAt: date(from: bucket["resets_at"] as? String),
                                          window: LimitBucket.weeklyWindow, severity: "normal")
        }
        return snapshot
    }

    /// Las marcas vienen con fracciones de 6 dígitos, que ISO8601DateFormatter no acepta.
    private static func date(from string: String?) -> Date? {
        guard var text = string else { return nil }
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            text.removeSubrange(dot..<end)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
