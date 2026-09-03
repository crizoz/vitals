import Foundation

/// Todo el texto que se ve pasa por acá. macOS resuelve el idioma solo: elige
/// el `.lproj` que mejor calce con el orden de idiomas del sistema —o con el
/// que el usuario le haya fijado a la app en Ajustes— y cae al inglés cuando no
/// hay ninguno. Agregar un idioma es soltar un `Localizable.strings` más en
/// `Resources/`, sin tocar una línea de Swift.
enum L10n {

    // MARK: Secciones

    static var sectionSystem: String { t("section.system") }
    static var sectionStorage: String { t("section.storage") }
    static var sectionClaude: String { t("section.claude") }

    // MARK: Sistema

    static var gaugeCPU: String { t("gauge.cpu") }
    static var gaugeGPU: String { t("gauge.gpu") }
    static var gaugeMemory: String { t("gauge.memory") }

    // MARK: Almacenamiento

    static var storageReading: String { t("storage.reading") }
    static var storageInternal: String { t("storage.internal") }
    static var storageExternal: String { t("storage.external") }
    static var storageUnnamed: String { t("storage.unnamed") }
    static func storageFree(_ size: String) -> String { t("storage.free", size) }
    static func storageHelp(kind: String, used: String, total: String) -> String {
        t("storage.help", kind, used, total)
    }

    // MARK: Claude

    static var claudeLoading: String { t("claude.loading") }
    static var claudeSession: String { t("claude.session") }
    static var claudeWeekly: String { t("claude.weekly") }
    static var claudeModel: String { t("claude.model") }
    static func claudeUsed(_ percent: String) -> String { t("claude.used", percent) }
    static func claudeUsedResets(_ percent: String, _ countdown: String) -> String {
        t("claude.usedResets", percent, countdown)
    }
    static func claudePace(_ percent: String) -> String { t("claude.pace", percent) }

    // MARK: Barra de menús

    static func menuBarTooltip(used: String, left: String) -> String {
        t("menubar.tooltip", used, left)
    }
    static func menuBarTooltipResets(_ countdown: String) -> String {
        t("menubar.tooltip.resets", countdown)
    }
    static var menuBarNoData: String { t("menubar.noData") }

    // MARK: Acciones y ajustes

    static var actionRefresh: String { t("action.refresh") }
    static var actionQuit: String { t("action.quit") }
    static var settingsShowPercent: String { t("settings.showPercent") }
    static var settingsLaunchAtLogin: String { t("settings.launchAtLogin") }

    static var helpKeyboardLock: String { t("help.keyboardLock") }
    static var helpCaffeineOn: String { t("help.caffeine.on") }
    static var helpCaffeineOff: String { t("help.caffeine.off") }
    static var helpScreenOff: String { t("help.screenOff") }

    // MARK: Frescura del dato

    static var freshnessNow: String { t("freshness.now") }
    static func freshnessMinutes(_ minutes: Int) -> String { t("freshness.minutes", minutes) }
    static func freshnessHours(_ hours: Int) -> String { t("freshness.hours", hours) }

    // MARK: Cuenta regresiva

    static var countdownNow: String { t("countdown.now") }
    static func countdownDays(_ days: Int, _ hours: Int) -> String { t("countdown.days", days, hours) }
    static func countdownHours(_ hours: Int, _ minutes: Int) -> String { t("countdown.hours", hours, minutes) }
    static func countdownMinutes(_ minutes: Int) -> String { t("countdown.minutes", minutes) }

    // MARK: Bloqueo del teclado

    static var lockTitle: String { t("lock.title") }
    static func lockSeconds(_ seconds: Int) -> String { t("lock.seconds", seconds) }
    static var lockNoteFull: String { t("lock.note.full") }
    static var lockNotePartial: String { t("lock.note.partial") }
    static var lockExtend: String { t("lock.extend") }
    static var lockFinish: String { t("lock.finish") }

    // MARK: Sin dormir

    static var sleepGuardAssertion: String { t("sleepGuard.assertion") }

    // MARK: Errores

    static var errorNoCredentials: String { t("error.noCredentials") }
    static var errorKeychainAccess: String { t("error.keychainAccess") }
    static func errorKeychain(_ status: Int32) -> String { t("error.keychain", String(status)) }
    static var errorRateLimited: String { t("error.rateLimited") }
    static var errorExpired: String { t("error.expired") }
    static func errorStatus(_ code: Int) -> String { t("error.status", String(code)) }

    // MARK: - Motor

    /// El texto de un idioma vive en su `Localizable.strings`; acá solo se
    /// resuelve la clave. Si faltara, se ve la clave cruda: `build.sh` compara
    /// las tablas contra estas claves justamente para que eso no llegue a la app.
    private static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    /// Los argumentos van posicionales (`%1$@`) porque el orden de una frase
    /// cambia entre idiomas.
    private static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: .current, arguments: arguments)
    }

    /// Vuelca el idioma que eligió macOS y el texto con que resolvió cada clave.
    /// Es la forma de comprobar desde la terminal que la app sigue al sistema:
    ///
    ///     Vitals.app/Contents/MacOS/Vitals --dump-strings -AppleLanguages "(es)"
    ///
    /// Una clave que salga igual a sí misma es una traducción que falta.
    static func dump() {
        print("localización: \(Bundle.main.preferredLocalizations.joined(separator: ", "))")
        print("región: \(Locale.current.identifier)")
        guard let url = Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                                        subdirectory: "en.lproj"),
              let table = NSDictionary(contentsOf: url) as? [String: String]
        else { return }
        for key in table.keys.sorted() { print("\(key) = \(t(key))") }

        // Las frases con argumentos hay que verlas armadas: un `%1$d` mal puesto
        // no se nota en la plantilla, se nota acá.
        let soon = Date().addingTimeInterval(3 * 3_600 + 900)
        print("— frases armadas —")
        print(menuBarTooltip(used: Format.percent(0.42), left: Format.percent(0.58))
              + menuBarTooltipResets(Format.countdown(to: soon)))
        print(storageFree(Format.bytesShort(886_000_000_000)))
        print(storageHelp(kind: storageInternal,
                          used: Format.bytes(400_000_000_000),
                          total: Format.bytes(994_000_000_000)))
        print(claudeUsed(Format.percent(0.07)))
        print(claudeUsedResets(Format.percent(0.42), Format.countdown(to: soon)))
        print(claudePace(Format.percent(0.6)))
        print([freshnessNow, freshnessMinutes(12), freshnessHours(3)].joined(separator: " · "))
        print([countdownNow, countdownMinutes(52), countdownHours(2, 5),
               countdownDays(4, 5)].joined(separator: " · "))
        print([lockTitle, lockSeconds(30), lockExtend, lockFinish].joined(separator: " · "))
        print([errorKeychain(-25_300), errorStatus(503)].joined(separator: " · "))
    }
}
