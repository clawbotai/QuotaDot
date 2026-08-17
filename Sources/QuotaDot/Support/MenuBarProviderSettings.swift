import Foundation
import Observation

@MainActor @Observable
final class MenuBarProviderSettings {
    static let storageKey = "QuotaDot.menuBarProviderId"

    private let defaults: UserDefaults

    var selectedProviderId: String? {
        didSet {
            if let selectedProviderId {
                defaults.set(selectedProviderId, forKey: Self.storageKey)
            } else {
                defaults.removeObject(forKey: Self.storageKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedProviderId = defaults.string(forKey: Self.storageKey)
    }

    func provider(from providers: [ProviderUsage]) -> ProviderUsage? {
        if let selectedProviderId,
           let selected = providers.first(where: {
               $0.providerId.caseInsensitiveCompare(selectedProviderId) == .orderedSame
           }) {
            return selected
        }
        return providers.first
    }
}
