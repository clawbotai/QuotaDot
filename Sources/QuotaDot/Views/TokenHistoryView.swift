import AppKit
import SwiftUI

struct TokenHistoryView: View {
    let store: TokenHistoryStore
    let quotaStore: QuotaStore
    let language: LanguageSettings
    @State private var granularity: TokenActivityGranularity = .daily

    var body: some View {
        ZStack {
            HistoryGlassBackdrop()

            Group {
                if !store.hasLoaded && store.errorMessageKey != nil {
                    errorState
                } else if !store.hasLoaded {
                    loadingState
                } else {
                    content
                }
            }
        }
        .frame(minWidth: 820, minHeight: 600)
        .task {
            await store.loadIfNeeded()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                await store.reload()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 10) {
                    if store.isLoading { ProgressView().controlSize(.small) }
                    Button {
                        Task {
                            async let historyRefresh: Void = store.reload()
                            async let quotaRefresh: Void = quotaStore.refresh()
                            _ = await (historyRefresh, quotaRefresh)
                        }
                    } label: {
                        Label(language.text("history.refresh"), systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isLoading)
                }
            }
        }
    }

    private var content: some View {
        ScrollView {
            contentSections
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var contentSections: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            summary
            TokenActivityHeatmap(
                dailyUsage: store.snapshot.dailyUsage,
                language: language,
                granularity: $granularity
            )
            providerBreakdown
            sourceNote
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(language.text("history.title"))
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text(language.text("history.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        Group {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 14) {
                    summaryMetrics
                }
            } else {
                summaryMetrics
            }
#else
            summaryMetrics
#endif
        }
        .help("\(QuotaFormatters.tokenCount(store.snapshot.totalTokens, language: language.language, compact: false)) Token")
    }

    private var summaryMetrics: some View {
        HStack(spacing: 14) {
            HistoryMetric(
                title: language.text("history.total"),
                value: formatted(store.snapshot.totalTokens),
                detail: historyRange,
                color: .blue
            )
            HistoryMetric(
                title: language.text("history.today"),
                value: formatted(store.snapshot.todayTokens),
                detail: language.text("history.calendarDay"),
                color: .green
            )
            HistoryMetric(
                title: language.text("history.month"),
                value: formatted(store.snapshot.monthTokens),
                detail: language.text("history.calendarMonth"),
                color: .indigo
            )
            HistoryMetric(
                title: language.text("history.week"),
                value: formatted(store.snapshot.weekTokens),
                detail: language.text("history.calendarWeek"),
                color: .cyan
            )
        }
    }

    private var providerBreakdown: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(language.text("history.tools.title"))
                .font(.system(size: 17, weight: .semibold))

            ForEach(Array(store.snapshot.providers.enumerated()), id: \.element.id) { item in
                if item.offset > 0 {
                    Divider()
                }
                providerUsageRow(item.element)
            }

            Label(language.text("history.estimate.note"), systemImage: "function")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(22)
        .quotaContentGlass(cornerRadius: 22)
    }

    private func providerUsageRow(_ provider: ProviderTokenUsage) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 24) {
                providerIdentity(provider)
                Spacer(minLength: 12)
                providerEstimate(provider)
            }

            HStack(spacing: 0) {
                providerMetric(title: language.text("history.tools.total"), value: provider.totalTokens)
                metricDivider
                providerMetric(title: language.text("history.today"), value: provider.todayTokens)
                metricDivider
                providerMetric(title: language.text("history.month"), value: provider.monthTokens)
                metricDivider
                providerMetric(title: language.text("history.week"), value: provider.weekTokens)
            }
        }
    }

    private func providerMetric(title: String, value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            tokenValue(value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricDivider: some View {
        Divider()
            .frame(height: 38)
            .padding(.horizontal, 16)
    }

    private func providerEstimate(_ provider: ProviderTokenUsage) -> some View {
        let estimate = estimate(for: provider)
        return VStack(alignment: .trailing, spacing: 3) {
            Text(language.text("history.estimate.title"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let estimate {
                Text(language.text("history.estimate.value", formatted(estimate.remainingTokens)))
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(estimateWindowLabel(estimate.window))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(language.text("history.estimate.insufficient"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 150, alignment: .trailing)
        .help(estimateHelp(estimate))
    }

    private func providerIdentity(_ provider: ProviderTokenUsage) -> some View {
        HStack(spacing: 12) {
            TokenToolLogo(providerId: provider.id)
            VStack(alignment: .leading, spacing: 6) {
                Text(provider.displayName)
                    .font(.system(size: 14, weight: .semibold))
                ProgressView(value: providerShare(provider))
                    .progressViewStyle(.linear)
                    .tint(providerTint(provider.id))
                    .frame(width: 160)
            }
        }
    }

    private func tokenValue(_ value: Int64) -> some View {
        Text(formatted(value))
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .help("\(QuotaFormatters.tokenCount(value, language: language.language, compact: false)) Token")
    }

    private var sourceNote: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "internaldrive")
                .foregroundStyle(.secondary)
            Text(sourceDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(language.text("history.loading"))
                .font(.headline)
            Text(language.text("history.loading.detail"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
    }

    private var errorState: some View {
        ContentUnavailableView(
            language.text("history.error.title"),
            systemImage: "exclamationmark.triangle",
            description: Text(language.text(store.errorMessageKey ?? "history.error"))
        )
    }

    private func formatted(_ value: Int64) -> String {
        QuotaFormatters.tokenCount(value, language: language.language)
    }

    private func providerShare(_ provider: ProviderTokenUsage) -> Double {
        guard store.snapshot.totalTokens > 0 else { return 0 }
        return Double(provider.totalTokens) / Double(store.snapshot.totalTokens)
    }

    private func providerTint(_ providerId: String) -> Color {
        switch providerId.lowercased() {
        case "claude": .orange
        case "kimi": .purple
        default: .blue
        }
    }

    private func estimate(for provider: ProviderTokenUsage) -> TokenCapacityEstimate? {
        let quotaProvider = quotaStore.providers.first {
            $0.providerId.caseInsensitiveCompare(provider.id) == .orderedSame
        }
        return TokenCapacityEstimator.estimate(
            providerId: provider.id,
            quotaProvider: quotaProvider,
            recentUsage: store.snapshot.recentUsage,
            historyGeneratedAt: store.snapshot.generatedAt,
            historyFirstActivityDate: provider.firstActivityDate
        )
    }

    private func estimateWindowLabel(_ window: TokenEstimateWindow) -> String {
        switch window {
        case .fiveHour: language.text("history.estimate.fiveHour")
        case .weekly: language.text("history.estimate.weekly")
        }
    }

    private func estimateHelp(_ estimate: TokenCapacityEstimate?) -> String {
        guard let estimate else { return language.text("history.estimate.help.unavailable") }
        return language.text(
            "history.estimate.help",
            QuotaFormatters.tokenCount(estimate.observedTokens, language: language.language, compact: false)
        )
    }

    private var historyRange: String {
        guard let start = store.snapshot.firstActivityDate else { return language.text("history.noActivity") }
        let formatter = DateFormatter()
        formatter.locale = language.language.locale
        formatter.dateFormat = language.language == .simplifiedChinese ? "yyyy.M.d" : "MMM d, yyyy"
        return language.text("history.since", formatter.string(from: start))
    }

    private var sourceDescription: String {
        let base = language.text("history.source", store.snapshot.scannedFileCount)
        guard store.snapshot.unreadableFileCount > 0 else { return base }
        return base + " " + language.text("history.source.unreadable", store.snapshot.unreadableFileCount)
    }
}

private struct HistoryMetric: View {
    let title: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minHeight: 116)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotaContentGlass(cornerRadius: 20)
    }
}

private struct HistoryGlassBackdrop: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [.blue.opacity(0.13), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 520
            )
            RadialGradient(
                colors: [.orange.opacity(0.07), .clear],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 460
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct TokenToolLogo: View {
    let providerId: String

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: opticalSize, height: opticalSize)
            } else if providerId.lowercased() == "kimi" {
                KimiProviderMark(size: 28)
            } else {
                Image(systemName: "sparkles")
            }
        }
        .frame(width: 28, height: 28)
    }

    private var opticalSize: CGFloat {
        providerId.lowercased() == "kimi" ? 28 * 0.805 : 28
    }

    private var image: NSImage? {
        let resourceName: String
        switch providerId.lowercased() {
        case "codex": resourceName = "codex-official"
        case "claude": resourceName = "claude-official"
        default: return nil
        }
        guard let url = QuotaResourceBundle.current.url(forResource: resourceName, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
