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
    /// Lee el token OAuth que Claude Code guarda en el llavero. Se relee en cada
    /// consulta porque el CLI lo rota.
    static func accessToken() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound { throw VitalsError.noCredentials }
        guard status == errSecSuccess else {
            FileHandle.standardError.write(Data("keychain OSStatus \(status)\n".utf8))
            throw VitalsError.keychain(status)
        }
        guard let data = item as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty
        else { throw VitalsError.noCredentials }
        return token
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
