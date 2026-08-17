import SwiftUI

struct BalanceProviderCard: View {
    let provider: ProviderUsage
    let status: DeepSeekRefreshStatus
    let language: LanguageSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                ProviderLogo(provider: provider, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(provider.plan ?? "API")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusLabel
            }

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(language.text("balance.topUp"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(provider.balance.map { QuotaFormatters.cny($0.toppedUp) } ?? "¥--")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                Text(freshnessText)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .frame(height: QuotaWindowMetrics.balanceCardHeight)
    }

    private var statusLabel: some View {
        let available = provider.balance?.isAvailable == true
        return Label(
            language.text(available ? "balance.available" : "balance.insufficient"),
            systemImage: available ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        )
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(available ? provider.accent : .red)
    }

    private var freshnessText: String {
        switch status {
        case let .cached(lastSuccessfulFetchAt, _, contractFailure, _):
            return language.text(
                contractFailure == nil ? "balance.cachedAt" : "balance.cachedContractAt",
                QuotaFormatters.clock(language: language.language).string(from: lastSuccessfulFetchAt)
            )
        case let .live(fetchedAt):
            return language.text(
                "balance.updatedAt",
                QuotaFormatters.clock(language: language.language).string(from: fetchedAt)
            )
        default:
            return language.text("footer.waiting")
        }
    }
}
