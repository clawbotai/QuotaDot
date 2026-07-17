import Foundation
import Observation

@MainActor @Observable
final class TokenHistoryStore {
    private static let maximumSnapshotAge: TimeInterval = 60

    private(set) var snapshot = TokenHistorySnapshot.empty
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessageKey: String?

    func loadIfNeeded(now: Date = .now) async {
        let age = now.timeIntervalSince(snapshot.generatedAt)
        let isCurrentDay = Calendar.autoupdatingCurrent.isDate(snapshot.generatedAt, inSameDayAs: now)
        guard !hasLoaded || age < 0 || age >= Self.maximumSnapshotAge || !isCurrentDay else { return }
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessageKey = nil
        defer { isLoading = false }

        do {
            let result = try await Task.detached(priority: .utility) {
                try TokenHistoryScanner.scan()
            }.value
            snapshot = result
            hasLoaded = true
        } catch {
            errorMessageKey = "history.error"
        }
    }
}
