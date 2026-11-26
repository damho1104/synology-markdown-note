import Foundation
import NoteCore

enum AppLocalization {
    static func applyProcessLanguagePreference() {
        guard let override = NoteLocalization.launchPreference.override else { return }
        // Give AppKit the same preference as our resource lookup for this launch.
        // The volatile argument domain is never written to macOS preferences.
        let defaults = UserDefaults.standard
        let domain = UserDefaults.argumentDomain
        var arguments = defaults.volatileDomain(forName: domain)
        arguments["AppleLanguages"] = [override]
        defaults.removeVolatileDomain(forName: domain)
        defaults.setVolatileDomain(arguments, forName: domain)
    }

    static let resources = Bundle.main.url(forResource: "SynologyNote_SynologyNote", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? Bundle.module
    static let bundle = NoteLocalization.localization(in: resources, language: NoteLocalization.language)
    static let locale = NoteLocalization.locale

    static func date(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }

    static func number(_ number: Int) -> String {
        number.formatted(.number.locale(locale))
    }

    static func blockLabel(_ label: String) -> String {
        // Older imports and source envelopes store these labels in Korean.
        switch label {
        case "원본 HTML": return appText("Original HTML")
        case "원본 표": return appText("Original Table")
        case "음성 첨부": return appText("Audio Attachment")
        case "원본 서식": return appText("Original Formatting")
        default: return label
        }
    }

    // CredentialStore.swift also builds the standalone, signed Keychain helper.
    static func errorMessage(_ error: Error) -> String {
        guard let credentialError = error as? CredentialStoreError else { return error.localizedDescription }
        switch credentialError {
        case .invalidAccount: return appText("A Keychain account identifier is required.")
        case .invalidData: return appText("Could not read the password data from Keychain.")
        case .keychain(let status): return appText("Keychain operation failed (%@).", String(status))
        }
    }
}

func appText(_ key: String, _ arguments: String...) -> String {
    NoteLocalization.text(key, arguments: arguments, in: AppLocalization.bundle)
}
