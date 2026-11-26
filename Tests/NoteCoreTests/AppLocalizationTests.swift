import Foundation
import Testing
@testable import NoteCore
@testable import SynologyNote

@Suite struct AppLocalizationTests {
    @Test func originalEditorDeclaresTheInterfaceLanguage() {
        let expected = NoteLocalization.language
        #expect(OriginalEditorRuntime.page.contains("<html lang=\"\(expected)\">"))
        #expect(MarkdownPipeline.previewPage("<p>원문</p>").contains("<html lang=\"\(expected)\">"))
    }

    @Test func resolvesOrderedLanguagePreferencesAndFallsBackToEnglish() {
        #expect(NoteLocalization.resolve(["fr-FR", "ko-KR", "en-GB"]) == "ko")
        #expect(NoteLocalization.resolve(["en-GB", "ko-KR"]) == "en")
        #expect(NoteLocalization.resolve(["fr-FR"]) == "en")
        #expect(NoteLocalization.resolve([]) == "en")
    }

    @Test func displayLanguagePersistsAndOverridesSystemPreferences() throws {
        let suite = "AppLocalizationTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(DisplayLanguagePreference.load(from: defaults) == .system)
        defaults.set("en", forKey: DisplayLanguagePreference.key)
        let explicit = DisplayLanguagePreference.load(from: defaults)
        #expect(explicit == .english)
        #expect(NoteLocalization.resolve(["ko-KR"], preference: explicit) == "en")
        defaults.set("ko", forKey: DisplayLanguagePreference.key)
        #expect(NoteLocalization.resolve(["en-GB"], preference: DisplayLanguagePreference.load(from: defaults)) == "ko")
        defaults.set("system", forKey: DisplayLanguagePreference.key)
        #expect(NoteLocalization.resolve(["ko-KR"], preference: DisplayLanguagePreference.load(from: defaults)) == "ko")
        defaults.set("invalid", forKey: DisplayLanguagePreference.key)
        #expect(DisplayLanguagePreference.load(from: defaults) == .system)
    }

    @Test func loadsBothResourceBundlesAndPreservesInterpolatedData() throws {
        let english = try #require(NoteLocalization.localization(in: AppLocalization.resources, language: "en"))
        let korean = try #require(NoteLocalization.localization(in: AppLocalization.resources, language: "ko"))
        let core = try #require(NoteLocalization.localization(in: NoteLocalization.coreResources, language: "ko"))
        #expect(english.localizedString(forKey: "Sign In", value: nil, table: nil) == "Sign In")
        #expect(korean.localizedString(forKey: "Sign In", value: nil, table: nil) == "로그인")
        #expect(core.localizedString(forKey: "Document Information", value: nil, table: nil) == "문서 정보")
        let key = "Downloading content and attachments %1$@/%2$@"
        #expect(NoteLocalization.text(key, arguments: ["50%", "2"], in: korean) == "본문·첨부 보관 중 50%/2")
    }

    @Test func englishResourceValuesContainNoKoreanInterfaceText() throws {
        for resources in [AppLocalization.resources, NoteLocalization.coreResources] {
            let bundle = try #require(NoteLocalization.localization(in: resources, language: "en"))
            let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let strings = try #require(PropertyListSerialization.propertyList(
                from: Data(contentsOf: url), format: nil
            ) as? [String: String])
            #expect(strings.values.filter { $0.range(of: "[가-힣]", options: .regularExpression) != nil }.isEmpty)
        }
    }

    @Test func mathExportKeepsItsStableFrontMatterLabel() throws {
        let source = "---\ntitle: Example\n---\n\n$x$"
        let preview = MarkdownPipeline.renderForPreview(source)
        let formula = try #require(MathExport.formulas(in: source).first)
        var image = NoteAttachment(name: "math.png", filename: "math.png", sha256: "", byteCount: 0)
        image.generatedMath = MathAttachmentMetadata(key: formula.key, width: 20, height: 10)
        let mathExport = try MathExport.html(markdown: source, blocks: [], attachments: [image])
        #expect(mathExport.contains("<summary>문서 정보</summary>"))
        #expect(preview.contains("<summary>\(coreText("Document Information"))</summary>"))
        #expect(mathExport.contains("title: Example"))
        #expect(mathExport.contains(image.reference))
    }
}
