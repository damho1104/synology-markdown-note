import Foundation

package enum DisplayLanguagePreference: String {
    case system, english = "en", korean = "ko"

    package static let key = "displayLanguagePreference"

    package static func load(from defaults: UserDefaults) -> Self {
        defaults.string(forKey: key).flatMap(Self.init(rawValue:)) ?? .system
    }

    package var override: String? { self == .system ? nil : rawValue }
}

package enum NoteLocalization {
    package static let preferences: UserDefaults = {
        guard let path = ProcessInfo.processInfo.environment["SYNOLOGY_NOTE_DATA_DIR"] else { return .standard }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        return UserDefaults(suiteName: "com.damho.SynologyMarkdown.verify." + root.lastPathComponent)!
    }()
    package static let launchPreference = DisplayLanguagePreference.load(from: preferences)

    // The main app bundle incorporates the macOS per-app language override.
    // SwiftPM test executables lack the app's Info.plist.
    package static let language: String = {
        let main = Bundle.main
        if main.localizations.contains("ko"), let preferred = main.preferredLocalizations.first {
            return resolve([preferred], preference: launchPreference)
        }
        return resolve(Locale.preferredLanguages, preference: launchPreference)
    }()

    package static func resolve(_ preferences: [String], preference: DisplayLanguagePreference = .system) -> String {
        if let override = preference.override { return override }
        for identifier in preferences {
            let code = Locale(identifier: identifier).language.languageCode?.identifier
            if code == "ko" { return "ko" }
            if code == "en" { return "en" }
        }
        return "en"
    }

    package static let locale = Locale(identifier: language)

    package static func localization(in bundle: Bundle, language: String) -> Bundle? {
        bundle.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:))
    }

    package static func text(_ key: String, arguments: [String], in bundle: Bundle?) -> String {
        let format = bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }

    package static let coreResources = Bundle.main.url(forResource: "SynologyNote_NoteCore", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? Bundle.module
    package static let coreBundle = localization(in: coreResources, language: language)
}

func coreText(_ key: String, _ arguments: String...) -> String {
    NoteLocalization.text(key, arguments: arguments, in: NoteLocalization.coreBundle)
}
