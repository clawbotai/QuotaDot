import Foundation

enum QuotaFormatters {
    static func reset(language: AppLanguage) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = language == .simplifiedChinese ? "M月d日 HH:mm" : "MMM d, HH:mm"
        return formatter
    }

    static func clock(language: AppLanguage) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    static func shortDate(language: AppLanguage) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateFormat = language == .simplifiedChinese ? "M/d" : "MMM d"
        return formatter
    }

    static func percent(_ remaining: Double?) -> String {
        guard let remaining else { return "--" }
        return "\(Int((remaining * 100).rounded()))%"
    }

    static func tokenCount(_ tokens: Int64, language: AppLanguage, compact: Bool = true) -> String {
        guard compact else {
            let formatter = NumberFormatter()
            formatter.locale = language.locale
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 0
            return formatter.string(from: NSNumber(value: tokens)) ?? "\(tokens)"
        }

        let value = Double(tokens)
        if language == .simplifiedChinese {
            if value >= 100_000_000 { return compactToken(value / 100_000_000, suffix: "亿") }
            if value >= 10_000 { return compactToken(value / 10_000, suffix: "万") }
        } else {
            if value >= 1_000_000_000_000 { return compactToken(value / 1_000_000_000_000, suffix: "T") }
            if value >= 1_000_000_000 { return compactToken(value / 1_000_000_000, suffix: "B") }
            if value >= 1_000_000 { return compactToken(value / 1_000_000, suffix: "M") }
            if value >= 1_000 { return compactToken(value / 1_000, suffix: "K") }
        }
        return tokenCount(tokens, language: language, compact: false)
    }

    private static func compactToken(_ value: Double, suffix: String) -> String {
        let digits = value >= 100 ? 0 : value >= 10 ? 1 : 2
        return String(format: "%.*f%@", digits, value, suffix)
    }

    @MainActor static func relativeReset(from date: Date, language: LanguageSettings, now: Date = .now) -> String {
        let seconds = max(date.timeIntervalSince(now), 0)
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours >= 24 { return language.text("time.daysHours", hours / 24, hours % 24) }
        if hours > 0 { return language.text("time.hoursMinutes", hours, minutes) }
        return language.text("time.minutes", minutes)
    }
}
