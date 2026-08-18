import Foundation
import Observation

@MainActor @Observable
final class ProviderVisibilitySettings {
    static let storageKey = "QuotaDot.hiddenProviderIds"

    private let defaults: UserDefaults
    private var hiddenIds: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.array(forKey: Self.storageKey) as? [String] {
            hiddenIds = Set(stored)
        }
    }

    func isVisible(_ provider: ProviderUsage) -> Bool {
        !hiddenIds.contains(provider.providerId.lowercased())
    }

    func isVisible(providerId: String) -> Bool {
        !hiddenIds.contains(providerId.lowercased())
    }

    func setVisible(_ visible: Bool, for provider: ProviderUsage) {
        setVisible(visible, providerId: provider.providerId)
    }

    func setVisible(_ visible: Bool, providerId: String) {
        let id = providerId.lowercased()
        if visible {
            hiddenIds.remove(id)
        } else {
            hiddenIds.insert(id)
        }
        persist()
    }

    func toggleVisibility(for provider: ProviderUsage) {
        setVisible(!isVisible(provider), for: provider)
    }

    private func persist() {
        defaults.set(Array(hiddenIds), forKey: Self.storageKey)
    }
}
