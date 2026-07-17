import Foundation

struct DailyTokenUsage: Identifiable, Sendable, Equatable {
    let date: Date
    let tokensByProvider: [String: Int64]

    var id: Date { date }
    var totalTokens: Int64 { tokensByProvider.values.reduce(0, +) }
}

struct ProviderTokenUsage: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let totalTokens: Int64
    let todayTokens: Int64
    let monthTokens: Int64
    let weekTokens: Int64
    let firstActivityDate: Date?
}

struct TimedProviderTokenUsage: Sendable, Equatable {
    let providerId: String
    let timestamp: Date
    let tokens: Int64
}

struct TokenHistorySnapshot: Sendable, Equatable {
    let totalTokens: Int64
    let todayTokens: Int64
    let monthTokens: Int64
    let weekTokens: Int64
    let providers: [ProviderTokenUsage]
    let dailyUsage: [DailyTokenUsage]
    let recentUsage: [TimedProviderTokenUsage]
    let scannedFileCount: Int
    let unreadableFileCount: Int
    let firstActivityDate: Date?
    let generatedAt: Date

    static let empty = TokenHistorySnapshot(
        totalTokens: 0,
        todayTokens: 0,
        monthTokens: 0,
        weekTokens: 0,
        providers: [],
        dailyUsage: [],
        recentUsage: [],
        scannedFileCount: 0,
        unreadableFileCount: 0,
        firstActivityDate: nil,
        generatedAt: .distantPast
    )
}

enum TokenActivityGranularity: String, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case cumulative

    var id: String { rawValue }
}
