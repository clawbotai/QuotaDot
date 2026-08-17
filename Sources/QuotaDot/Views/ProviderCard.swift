import AppKit
import SwiftUI

struct ProviderCard: View {
    let provider: ProviderUsage
    let isConsuming: Bool
    let resetCredits: CodexResetCredits?
    let language: LanguageSettings
    @State private var showResetCredits = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                ProviderLogo(provider: provider, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(provider.plan ?? language.text("provider.connected"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                activityLabel
            }

            HStack(alignment: .center, spacing: 18) {
                if let session = provider.session {
                    metric(title: language.text("quota.session"), line: session, emphasized: true)
                }
                if let weekly = provider.weekly {
                    if provider.session != nil {
                        Rectangle()
                            .fill(.primary.opacity(0.09))
                            .frame(width: 0.5, height: 78)
                    }
                    metric(title: language.text("quota.weekly"), line: weekly, emphasized: provider.session == nil)
                }
            }

            if let resetCredits {
                resetCreditRow(resetCredits)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(height: resetCredits == nil
            ? QuotaWindowMetrics.quotaCardHeight
            : QuotaWindowMetrics.quotaCardWithCreditsHeight)
    }

    private var activityLabel: some View {
        HStack(spacing: 6) {
            activityIndicator
            Text(language.text(isConsuming ? "provider.active" : "provider.idle"))
                .font(.system(size: 9.5, weight: .medium))
        }
        .foregroundStyle(isConsuming ? provider.accent : .secondary)
    }

    private var activityIndicator: some View {
        TimelineView(.animation(minimumInterval: isConsuming && !reduceMotion ? 1 / 20 : 1)) { timeline in
            let phase = isConsuming && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0
            ZStack {
                Circle()
                    .fill(isConsuming ? provider.accent.opacity(0.16) : Color.secondary.opacity(0.12))
                Circle()
                    .fill(isConsuming ? provider.accent : Color.secondary.opacity(0.35))
                    .frame(width: 4.5, height: 4.5)
                if isConsuming {
                    Circle()
                        .trim(from: 0.08, to: 0.62)
                        .stroke(provider.accent.opacity(0.86), style: StrokeStyle(lineWidth: 1.15, lineCap: .round))
                        .padding(2)
                        .rotationEffect(.degrees(phase.truncatingRemainder(dividingBy: 2.2) / 2.2 * 360))
                }
            }
        }
        .frame(width: 15, height: 15)
    }

    private func metric(title: String, line: UsageLine, emphasized: Bool) -> some View {
        QuotaRing(
            title: title,
            remaining: line.remainingPercent,
            resetAt: provider.effectiveResetAt(for: line),
            expanded: emphasized && provider.session == nil,
            language: language
        )
        .frame(maxWidth: .infinity)
    }

    private func resetCreditRow(_ credits: CodexResetCredits) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(provider.accent)
            Text(language.text("credits.available", credits.availableCount))
                .font(.system(size: 9.5, weight: .semibold))
            Spacer()
            if credits.availableCount > 0 {
                Button(language.text("credits.viewExpiry")) { showResetCredits.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(provider.accent)
                    .popover(isPresented: $showResetCredits, arrowEdge: .trailing) {
                        resetCreditPopover(credits)
                    }
            }
        }
        .padding(.top, 1)
    }

    private func resetCreditPopover(_ credits: CodexResetCredits) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(language.text("credits.title"))
                    .font(.system(size: 14, weight: .semibold))
                Text(language.text("credits.current", credits.availableCount))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Divider()
            if credits.expirations.isEmpty {
                Text(language.text("credits.noExpiry"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(credits.expirations.enumerated()), id: \.offset) { index, date in
                    HStack(spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(provider.accent)
                            .frame(width: 20, height: 20)
                            .background(provider.accent.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Full reset")
                                .font(.system(size: 10, weight: .semibold))
                            Text(language.text(
                                "credits.expires",
                                QuotaFormatters.reset(language: language.language).string(from: date)
                            ))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 220)
    }
}

struct ProviderLogo: View {
    let provider: ProviderUsage
    let size: CGFloat

    var body: some View {
        Group {
            if let image = providerImage {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: opticalSize, height: opticalSize)
            } else {
                Image(systemName: "sparkles")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(provider.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private var opticalSize: CGFloat {
        provider.providerId.lowercased() == "kimi" ? size * 0.805 : size
    }

    private var providerImage: NSImage? {
        let name: String
        switch provider.providerId.lowercased() {
        case "codex": name = "codex-official"
        case "claude": name = "claude-official"
        case "kimi": name = "kimi-official"
        case "deepseek": name = "deepseek-official"
        default: return nil
        }
        guard let url = QuotaResourceBundle.current.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct KimiProviderMark: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: officialImage)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size * 0.805, height: size * 0.805)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.805 * 0.24, style: .continuous))
            .frame(width: size, height: size)
    }

    private var officialImage: NSImage {
        guard let url = QuotaResourceBundle.current.url(forResource: "kimi-official", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage()
        }
        return image
    }
}
