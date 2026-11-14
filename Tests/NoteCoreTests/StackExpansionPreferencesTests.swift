import Foundation
import Testing
@testable import SynologyNote

@Suite struct StackExpansionPreferencesTests {
    @Test func stacksStartCollapsedAndRememberLastToggleAcrossReloads() {
        let suite = "stack-expansion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = StackExpansionPreferences(defaults: defaults, accountKey: "account-a")

        #expect(account.load().isEmpty)
        #expect(account.setExpanded(true, for: "LLM-Daily-Summary") == ["LLM-Daily-Summary"])
        #expect(StackExpansionPreferences(defaults: defaults, accountKey: "account-a").load() == ["LLM-Daily-Summary"])
        #expect(StackExpansionPreferences(defaults: defaults, accountKey: "account-b").load().isEmpty)
        #expect(account.setExpanded(false, for: "LLM-Daily-Summary").isEmpty)
        #expect(account.load().isEmpty)
    }
}
