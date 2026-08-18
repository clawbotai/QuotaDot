import Foundation
import Testing
@testable import QuotaDot

@MainActor
struct ProviderVisibilitySettingsTests {

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "ProviderVisibilitySettingsTests.\(UUID().uuidString)")!
    }

    @Test
    func defaultsToVisibleForAllProviders() async throws {
        let defaults = makeDefaults()
        let settings = ProviderVisibilitySettings(defaults: defaults)
        let provider = ProviderUsage(
            providerId: "codex",
            displayName: "Codex",
            plan: nil,
            lines: [],
            fetchedAt: nil
        )
        #expect(settings.isVisible(provider))
        #expect(settings.isVisible(providerId: "claude"))
    }

    @Test
    func hidesAndShowsProvider() async throws {
        let defaults = makeDefaults()
        let settings = ProviderVisibilitySettings(defaults: defaults)
        let provider = ProviderUsage(
            providerId: "Codex",
            displayName: "Codex",
            plan: nil,
            lines: [],
            fetchedAt: nil
        )

        settings.setVisible(false, for: provider)
        #expect(!settings.isVisible(provider))
        #expect(!settings.isVisible(providerId: "codex"))

        settings.setVisible(true, for: provider)
        #expect(settings.isVisible(provider))
    }

    @Test
    func persistsHiddenProvidersAcrossInstances() async throws {
        let defaults = makeDefaults()
        let first = ProviderVisibilitySettings(defaults: defaults)
        let provider = ProviderUsage(
            providerId: "claude",
            displayName: "Claude",
            plan: nil,
            lines: [],
            fetchedAt: nil
        )
        first.setVisible(false, for: provider)

        let second = ProviderVisibilitySettings(defaults: defaults)
        #expect(!second.isVisible(provider))
    }

    @Test
    func matchingIsCaseInsensitive() async throws {
        let defaults = makeDefaults()
        let settings = ProviderVisibilitySettings(defaults: defaults)
        let provider = ProviderUsage(
            providerId: "Kimi",
            displayName: "Kimi",
            plan: nil,
            lines: [],
            fetchedAt: nil
        )
        settings.setVisible(false, providerId: "kimi")
        #expect(!settings.isVisible(provider))
    }

    @Test
    func toggleFlipsVisibility() async throws {
        let defaults = makeDefaults()
        let settings = ProviderVisibilitySettings(defaults: defaults)
        let provider = ProviderUsage(
            providerId: "kimi",
            displayName: "Kimi",
            plan: nil,
            lines: [],
            fetchedAt: nil
        )
        settings.toggleVisibility(for: provider)
        #expect(!settings.isVisible(provider))
        settings.toggleVisibility(for: provider)
        #expect(settings.isVisible(provider))
    }
}
