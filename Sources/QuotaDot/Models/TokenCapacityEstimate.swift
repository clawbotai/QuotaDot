import Foundation

enum TokenEstimateWindow: Sendable, Equatable {
    case fiveHour
    case weekly
}

struct TokenCapacityEstimate: Sendable, Equatable {
    let window: TokenEstimateWindow
    let observedTokens: Int64
    let remainingTokens: Int64
    let windowStart: Date
    let resetsAt: Date
}

enum TokenCapacityEstimator {
    private static let maximumSnapshotSkew: TimeInterval = 2 * 60
    private static let maximumSessionDuration: TimeInterval = 12 * 60 * 60
    private static let maximumRetainedWindowDuration: TimeInterval = 8 * 24 * 60 * 60

    static func estimate(
        providerId: String,
        quotaProvider: ProviderUsage?,
        recentUsage: [TimedProviderTokenUsage],
        historyGeneratedAt: Date,
        historyFirstActivityDate: Date?
    ) -> TokenCapacityEstimate? {
        guard let quotaProvider else { return nil }
        if let fetchedAt = quotaProvider.fetchedAt,
           abs(fetchedAt.timeIntervalSince(historyGeneratedAt)) > maximumSnapshotSkew {
            return nil
        }

        let referenceDate = min(historyGeneratedAt, quotaProvider.fetchedAt ?? historyGeneratedAt)
        if let session = quotaProvider.session,
           let candidate = candidate(for: session, window: .fiveHour, provider: quotaProvider, referenceDate: referenceDate) {
            return estimate(
                candidate: candidate,
                providerId: providerId,
                recentUsage: recentUsage,
                historyFirstActivityDate: historyFirstActivityDate,
                referenceDate: referenceDate
            )
        }

        for weekly in weeklyCandidates(for: quotaProvider) {
            guard let candidate = candidate(
                for: weekly,
                window: .weekly,
                provider: quotaProvider,
                referenceDate: referenceDate
            ) else { continue }
            return estimate(
                candidate: candidate,
                providerId: providerId,
                recentUsage: recentUsage,
                historyFirstActivityDate: historyFirstActivityDate,
                referenceDate: referenceDate
            )
        }
        return nil
    }

    private static func weeklyCandidates(for provider: ProviderUsage) -> [UsageLine] {
        var candidates: [UsageLine] = []
        var seen: Set<String> = []

        func append(_ line: UsageLine?) {
            guard let line, seen.insert(line.id).inserted else { return }
            candidates.append(line)
        }

        append(provider.weekly)
        let weeklyLabels: Set<String> = ["weekly", "week", "seven day", "spark", "7d"]
        for line in provider.lines where line.type == "progress" && weeklyLabels.contains(line.label.lowercased()) {
            append(line)
        }
        return candidates
    }

    private static func candidate(
        for line: UsageLine,
        window: TokenEstimateWindow,
        provider: ProviderUsage,
        referenceDate: Date
    ) -> EstimateCandidate? {
        guard let durationMilliseconds = line.periodDurationMs else { return nil }
        let duration = durationMilliseconds / 1_000
        switch window {
        case .fiveHour:
            guard duration > 0, duration <= maximumSessionDuration else { return nil }
        case .weekly:
            guard duration > maximumSessionDuration, duration <= maximumRetainedWindowDuration else { return nil }
        }

        guard let resetsAt = provider.effectiveResetAt(for: line) else { return nil }
        let windowStart = resetsAt.addingTimeInterval(-duration)
        guard resetsAt > referenceDate, windowStart <= referenceDate else { return nil }
        return EstimateCandidate(line: line, window: window, windowStart: windowStart, resetsAt: resetsAt)
    }

    private static func estimate(
        candidate: EstimateCandidate,
        providerId: String,
        recentUsage: [TimedProviderTokenUsage],
        historyFirstActivityDate: Date?,
        referenceDate: Date
    ) -> TokenCapacityEstimate? {
        if let historyFirstActivityDate,
           Calendar.autoupdatingCurrent.startOfDay(for: historyFirstActivityDate)
            > Calendar.autoupdatingCurrent.startOfDay(for: candidate.windowStart) {
            return nil
        }

        let observedTokens = recentUsage.lazy
            .filter { usage in
                usage.providerId.caseInsensitiveCompare(providerId) == .orderedSame
                    && usage.timestamp >= candidate.windowStart
                    && usage.timestamp <= referenceDate
            }
            .reduce(Int64(0)) { partial, usage in
                partial.addingReportingOverflow(usage.tokens).overflow
                    ? Int64.max
                    : partial + usage.tokens
            }

        guard let usedFraction = candidate.line.usedPercent else { return nil }
        if usedFraction >= 1 {
            return TokenCapacityEstimate(
                window: candidate.window,
                observedTokens: observedTokens,
                remainingTokens: 0,
                windowStart: candidate.windowStart,
                resetsAt: candidate.resetsAt
            )
        }

        guard usedFraction >= 0.01, observedTokens > 0 else { return nil }
        let remaining = Double(observedTokens) * (1 - usedFraction) / usedFraction
        guard remaining.isFinite, remaining <= Double(Int64.max) else { return nil }

        return TokenCapacityEstimate(
            window: candidate.window,
            observedTokens: observedTokens,
            remainingTokens: Int64(remaining.rounded(.down)),
            windowStart: candidate.windowStart,
            resetsAt: candidate.resetsAt
        )
    }
}

private struct EstimateCandidate {
    let line: UsageLine
    let window: TokenEstimateWindow
    let windowStart: Date
    let resetsAt: Date
}
