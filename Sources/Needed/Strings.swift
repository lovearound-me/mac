import AppKit

/// The app's languages: the dictionaries in i18n/<lang>.json at the top of the
/// repository, copied into
/// Contents/Resources/i18n by build.sh and keyed by the Russian text.
///
///     tr("Пауза до {time}", ["time": "08:00"])
///     trn("{n} человек", 5)     // plural forms by the CLDR rules of the language
///
/// The language is the one chosen in Settings (UserDefaults "language"), or
/// the first of the Mac's preferred languages that the app has, or English.
/// It is read once: a change in Settings restarts the app.
final class Strings {
    /// The site's languages by their own names, in its order.
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Español"), ("pt", "Português"), ("de", "Deutsch"), ("fr", "Français"),
        ("it", "Italiano"), ("pl", "Polski"), ("tr", "Türkçe"), ("uk", "Українська"), ("ru", "Русский"),
        ("id", "Bahasa Indonesia"), ("ko", "한국어"), ("zh", "中文"),
    ]
    static let fallback = "en"
    static let defaultsKey = "language"

    static let shared = Strings(choice: UserDefaults.standard.string(forKey: defaultsKey) ?? "")

    /// For dates and numbers in the app's language rather than the system's.
    static var locale: Locale { Locale(identifier: shared.lang) }

    /// Saves the choice ("" for the Mac's) and starts the app again in it,
    /// back in Settings: every menu and window is built in one language.
    @MainActor
    static func choose(_ code: String) {
        guard code != (UserDefaults.standard.string(forKey: defaultsKey) ?? "") else { return }
        UserDefaults.standard.set(code, forKey: defaultsKey)
        UserDefaults.standard.synchronize()
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.1; done; "
            + "open \"$0\" --args --settings", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    /// Started again by `choose`: Settings open on the tab with the language.
    static var reopenSettings: Bool { CommandLine.arguments.contains("--settings") }

    let lang: String
    private let table: [String: Any]
    private let english: [String: Any]

    init(choice: String) {
        lang = Strings.resolve(choice)
        table = Strings.load(lang)
        english = lang == "ru" || lang == Strings.fallback ? [:] : Strings.load(Strings.fallback)
    }

    /// The chosen language, else the Mac's, else English.
    static func resolve(_ choice: String) -> String {
        let codes = languages.map(\.code)
        if codes.contains(choice) { return choice }
        for preferred in Locale.preferredLanguages {
            let code = String(preferred.prefix { $0 != "-" && $0 != "_" }).lowercased()
            if codes.contains(code) { return code }
        }
        return fallback
    }

    private static func load(_ code: String) -> [String: Any] {
        guard let url = Bundle.main.url(forResource: code, withExtension: "json", subdirectory: "i18n"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    func text(_ key: String) -> String {
        table[key] as? String ?? english[key] as? String ?? key
    }

    func plural(_ key: String, _ n: Int) -> String {
        if let forms = table[key] as? [String: String] {
            return Strings.pick(forms, Strings.category(lang, n)) ?? key
        }
        if let forms = english[key] as? [String: String] {
            return Strings.pick(forms, Strings.category(Strings.fallback, n)) ?? key
        }
        return key
    }

    private static func pick(_ forms: [String: String], _ category: String) -> String? {
        forms[category] ?? forms["other"] ?? forms["many"]
    }

    /// CLDR cardinal categories for whole numbers, for the app's languages.
    static func category(_ lang: String, _ number: Int) -> String {
        let n = abs(number)
        switch lang {
        case "ru", "uk":
            if n % 10 == 1 && n % 100 != 11 { return "one" }
            if (2...4).contains(n % 10) && !(12...14).contains(n % 100) { return "few" }
            return "many"
        case "pl":
            if n == 1 { return "one" }
            if (2...4).contains(n % 10) && !(12...14).contains(n % 100) { return "few" }
            return "many"
        case "fr", "pt":
            return n <= 1 ? "one" : "other"
        case "id", "ko", "zh":
            return "other"
        default:
            return n == 1 ? "one" : "other"
        }
    }
}

private func fill(_ text: String, _ args: [String: Any]) -> String {
    var text = text
    for (key, value) in args {
        text = text.replacingOccurrences(of: "{\(key)}", with: "\(value)")
    }
    return text
}

/// `text` in the app's language, its {placeholders} filled from `args`.
func tr(_ text: String, _ args: [String: Any] = [:]) -> String {
    fill(Strings.shared.text(text), args)
}

/// `text` with {n}: the form for `n` in the app's language.
func trn(_ text: String, _ n: Int, _ args: [String: Any] = [:]) -> String {
    var args = args
    args["n"] = n
    return fill(Strings.shared.plural(text, n), args)
}
