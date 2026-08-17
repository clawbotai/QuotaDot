import Foundation
import Testing
@testable import QuotaDot

@MainActor
struct MenuBarProviderSettingsTests {
    @Test func defaultsToTheFirstProviderAndPersistsTheSelectedProvider() {
        let defaults = UserDefaults(suiteName: "MenuBarProviderSettingsTests.\(UUID().uuidString)")!
        let settings = MenuBarProviderSettings(defaults: defaults)
        let providers = [
            ProviderUsage(providerId: "codex", displayName: "Codex", plan: nil, lines: [], fetchedAt: nil),
            ProviderUsage(
                providerId: "deepseek",
                displayName: "DeepSeek",
                plan: nil,
                lines: [],
                fetchedAt: nil,
                balance: ProviderBalance(currency: "CNY", toppedUp: 13.4, isAvailable: true)
            )
        ]

        #expect(settings.provider(from: providers)?.providerId == "codex")

        settings.selectedProviderId = "deepseek"

        #expect(settings.provider(from: providers)?.providerId == "deepseek")
        #expect(defaults.string(forKey: MenuBarProviderSettings.storageKey) == "deepseek")
    }
}
