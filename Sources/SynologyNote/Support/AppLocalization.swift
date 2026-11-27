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

    static func syncAttentionMessage(_ message: String?, language: String = NoteLocalization.language) -> String? {
        guard let message = syncErrorMessage(message, language: language) else { return nil }
        let bundle = NoteLocalization.localization(in: NoteLocalization.coreResources, language: language)
        let automaticVerification = [
            "The NAS save could not be confirmed yet. The source was kept while verification continues.",
            "The previous upload could not be confirmed. Check the server before creating the note again."
        ]
        return automaticVerification.contains { NoteLocalization.text($0, arguments: [], in: bundle) == message } ? nil : message
    }

    // Older notes and queued operations store rendered errors. Match only
    // known messages so repository and server diagnostics stay intact.
    static func syncErrorMessage(_ message: String?, language: String = NoteLocalization.language) -> String? {
        guard let message else { return nil }
        let coreKeys = [
            "Check the references to preserved blocks.",
            "The NAS save could not be confirmed yet. The source was kept while verification continues.",
            "The previous upload could not be confirmed. Check the server before creating the note again.",
            "The note changed on the NAS first. Review both versions.",
            "The official app changed this note. Review both versions.",
            "The math image renderer is unavailable. The source was preserved.",
            "Another local edit exists for the same NAS note.",
            "Another local edit exists for the same NAS note. The edits cannot be merged automatically.",
            "The NAS note association changed during upload.",
            "Sign in to the NAS first.",
            "The NAS session expired. Sign in again.",
            "You don’t have permission to access this note.",
            "The Note Station response did not match the expected format.",
            "The note changed on the NAS first. The server rejected the older version (1064)."
        ]
        let appKey = "This note changed on this Mac while its body was downloading. Review both versions."
        let sourceLanguage = language == "ko" ? "en" : "ko"
        let coreSource = NoteLocalization.localization(in: NoteLocalization.coreResources, language: sourceLanguage)
        let coreTarget = NoteLocalization.localization(in: NoteLocalization.coreResources, language: language)
        if let key = coreKeys.first(where: { NoteLocalization.text($0, arguments: [], in: coreSource) == message }) {
            return NoteLocalization.text(key, arguments: [], in: coreTarget)
        }
        let appSource = NoteLocalization.localization(in: resources, language: sourceLanguage)
        if NoteLocalization.text(appKey, arguments: [], in: appSource) == message {
            let appTarget = NoteLocalization.localization(in: resources, language: language)
            return NoteLocalization.text(appKey, arguments: [], in: appTarget)
        }
        for key in ["The NAS HTTP request failed (%@).", "The NAS network request failed (%@).", "The Note Station API request failed (%@)."] {
            let format = NoteLocalization.text(key, arguments: [], in: coreSource)
            let parts = format.components(separatedBy: "%@")
            guard parts.count == 2, message.hasPrefix(parts[0]), message.hasSuffix(parts[1]),
                  message.count > parts[0].count + parts[1].count else { continue }
            let code = message.dropFirst(parts[0].count).dropLast(parts[1].count)
            guard Int(code) != nil else { continue }
            return NoteLocalization.text(key, arguments: [String(code)], in: coreTarget)
        }
        return message
    }
}

func appText(_ key: String, _ arguments: String...) -> String {
    NoteLocalization.text(key, arguments: arguments, in: AppLocalization.bundle)
}
