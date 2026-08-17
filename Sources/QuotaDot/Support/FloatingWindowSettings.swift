import Foundation
import Observation

@MainActor @Observable
final class FloatingWindowSettings {
    static let storageKey = "QuotaDot.floatingWindowEnabled"

    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.storageKey) }
    }

    init(defaults: UserDefaults = .standard) {
        isEnabled = defaults.object(forKey: Self.storageKey) as? Bool ?? true
    }
}
