import SwiftUI

struct FloatingQuotaView: View {
    let store: QuotaStore
    let language: LanguageSettings
    @Binding var compact: Bool

    var body: some View {
        if compact { compactView } else { expandedView }
    }

    private var compactView: some View {
        Group {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 0) {
                    compactBadges
                }
            } else {
                compactBadges
            }
#else
            compactBadges
#endif
        }
        .frame(width: compactWidth, height: 56)
        .contentShape(Rectangle())
        .onTapGesture { compact = false }
        .onHover { if $0 { compact = false } }
    }

    private var compactBadges: some View {
        let activeProviderIds = store.activeProviderIds
        return HStack(spacing: 8) {
            ForEach(store.providers) { provider in
                CompactProviderBadge(
                    provider: provider,
                    remaining: providerLowest(provider),
                    active: provider.balance == nil && activeProviderIds.contains(provider.id),
                    status: provider.providerId.lowercased() == "deepseek" ? store.deepSeekStatus : .idle,
                    language: language
                )
            }
        }
    }

    private var expandedView: some View {
        let activeProviderIds = store.activeProviderIds
        return ZStack {
            WeatherBackdrop(weather: store.weather, fallbackHealth: store.health)

            VStack(spacing: 0) {
                header
                if store.providers.isEmpty {
                    unavailableState
                } else {
                    ForEach(Array(store.providers.enumerated()), id: \.element.id) { index, provider in
                        if index > 0 {
                            Divider()
                                .frame(height: QuotaWindowMetrics.dividerHeight)
                                .padding(.horizontal, 20)
                                .opacity(0.30)
                        }
                        if provider.balance != nil {
                            BalanceProviderCard(
                                provider: provider,
                                status: store.deepSeekStatus,
                                language: language
                            )
                        } else {
                            ProviderCard(
                                provider: provider,
                                isConsuming: activeProviderIds.contains(provider.id),
                                resetCredits: provider.providerId.lowercased() == "codex" ? store.codexResetCredits : nil,
                                language: language
                            )
                        }
                    }
                }
                footer
            }
            .quotaLiquidGlass(cornerRadius: 28)
        }
        .frame(width: 356)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.90), .white.opacity(0.28), .white.opacity(0.68)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.85
                )
        }
        .shadow(color: store.health.shadowColor, radius: 32, y: 14)
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI USAGE")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Circle()
                        .fill(store.health.color)
                        .frame(width: 5, height: 5)
                    Text(statusCopy)
                    Button { language.toggle() } label: {
                        Text(language.language.shortLabel)
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help(language.text("header.switchLanguage"))
                    if let weather = store.weather {
                        Text("·").opacity(0.55)
                        Label(
                            weatherSummary(weather),
                            systemImage: weather.symbolName
                        )
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .help(weatherDetail(weather))
                    } else if let locationStatusKey = store.locationStatusKey {
                        Text("·").opacity(0.55)
                        Label(language.text(locationStatusKey), systemImage: "location.slash")
                            .labelStyle(.titleAndIcon)
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if store.hasQuotaProviders {
                Text(QuotaFormatters.percent(store.lowestRemaining))
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Button { compact = true } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 25, height: 25)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: 62)
    }

    private var footer: some View {
        HStack {
            Text(store.lastUpdated.map {
                language.text("footer.updated", QuotaFormatters.clock(language: language.language).string(from: $0))
            } ?? language.text("footer.waiting"))
            Spacer()
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .frame(height: 34)
    }

    private var unavailableState: some View {
        ContentUnavailableView(
            language.text("empty.title"),
            systemImage: "bolt.horizontal.circle",
            description: Text(language.text(store.errorMessageKey ?? "empty.connecting"))
        )
            .frame(height: 170)
    }

    private var statusCopy: String {
        if store.hasQuotaProviders {
            if store.errorMessageKey != nil { return language.text("status.cached") }
            return switch store.health {
            case .healthy: language.text("status.healthy")
            case .warning: language.text("status.warning")
            case .critical: language.text("status.critical")
            case .unknown: language.text("status.connecting")
            }
        }
        if store.deepSeekProvider != nil {
            if case .cached = store.deepSeekStatus { return language.text("status.cached") }
            return language.text("balance.connected")
        }
        return language.text("status.connecting")
    }

    private func weatherSummary(_ weather: WeatherSnapshot) -> String {
        let location = weather.displayLocation(language: language.language)
        if language.language == .english { return "\(location) · \(weather.temperature)°" }
        return "\(location) \(weather.condition(language: language)) \(weather.temperature)°"
    }

    private func weatherDetail(_ weather: WeatherSnapshot) -> String {
        "\(weather.displayLocation(language: language.language)) · \(weather.condition(language: language)) · \(weather.temperature)°"
    }

    private var compactWidth: CGFloat { QuotaWindowMetrics.compactWidth(providerCount: store.providers.count) }
    private func providerLowest(_ provider: ProviderUsage) -> Double? { [provider.session?.remainingPercent, provider.weekly?.remainingPercent].compactMap { $0 }.min() }
}

private struct CompactProviderBadge: View {
    let provider: ProviderUsage
    let remaining: Double?
    let active: Bool
    let status: DeepSeekRefreshStatus
    let language: LanguageSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var health: QuotaHealth { QuotaHealth(remaining: remaining) }
    private let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)

    var body: some View {
        ZStack {
            if active {
                activityMarquee
            }

            badgeSurface
                .frame(width: active ? 47.2 : 52, height: active ? 47.2 : 52)
        }
        .frame(width: 52, height: 52)
        // A compact NSPanel only leaves two points around this badge. An
        // outward shadow on the glass compositing layer is clipped by the
        // rectangular window boundary and becomes visible over light windows.
        // Keep every animated pixel inside the badge's continuous corner.
        .clipShape(shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityCopy)
    }

    private var badgeSurface: some View {
        let innerShape = RoundedRectangle(cornerRadius: active ? 15 : 17, style: .continuous)
        return ZStack {
            innerShape
                .fill(
                    LinearGradient(
                        colors: badgeColors.map { $0.opacity(0.30) },
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RadialGradient(
                colors: [.white.opacity(0.62), .white.opacity(0.05), .clear],
                center: .topLeading,
                startRadius: 1,
                endRadius: 48
            )
            .clipShape(innerShape)

            VStack(spacing: 3) {
                ProviderLogo(provider: provider, size: 20)
                Text(compactMetric)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(.top, 1)
        }
        .quotaCompactGlass(cornerRadius: active ? 15 : 17)
        .overlay {
            innerShape
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.82), .white.opacity(0.18), .white.opacity(0.48)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.7
                )
        }
        .overlay(alignment: .topTrailing) {
            if let balance = provider.balance {
                Circle()
                    .fill(balance.isAvailable ? provider.accent : Color.red)
                    .frame(width: 5, height: 5)
                    .padding(7)
            }
        }
    }

    private var badgeColors: [Color] {
        provider.balance == nil ? health.backgroundColors : provider.softPalette
    }

    private var compactMetric: String {
        if let balance = provider.balance { return QuotaFormatters.compactCNY(balance.toppedUp) }
        return QuotaFormatters.percent(remaining)
    }

    private var accessibilityCopy: String {
        if let balance = provider.balance {
            let availability = language.text(balance.isAvailable ? "balance.available" : "balance.insufficient")
            let freshness = if case .cached = status { language.text("balance.cached") } else { "" }
            return "\(provider.displayName) \(QuotaFormatters.cny(balance.toppedUp)) \(availability) \(freshness)"
        }
        return "\(provider.displayName) \(QuotaFormatters.percent(remaining)) \(active ? language.text("provider.active") : language.text("provider.idle"))"
    }

    @ViewBuilder
    private var activityMarquee: some View {
        if active {
            TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1 / 24)) { timeline in
                let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let angle = Angle.degrees(phase.truncatingRemainder(dividingBy: 2.8) / 2.8 * 360)
                shape
                    .fill(
                        AngularGradient(
                            gradient: Gradient(stops: [
                                .init(color: provider.accent.opacity(0.72), location: 0.00),
                                .init(color: provider.accent, location: 0.18),
                                .init(color: .white, location: 0.30),
                                .init(color: provider.accent, location: 0.42),
                                .init(color: provider.accent.opacity(0.62), location: 0.65),
                                .init(color: .white.opacity(0.92), location: 0.82),
                                .init(color: provider.accent, location: 0.90),
                                .init(color: provider.accent.opacity(0.72), location: 1.00)
                            ]),
                            center: .center,
                            startAngle: angle,
                            endAngle: angle + .degrees(360)
                        )
                    )
                    .overlay {
                        shape
                            .strokeBorder(.white.opacity(0.34), lineWidth: 0.7)
                            .padding(0.55)
                    }
                    .padding(0.15)
            }
        }
    }
}
