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

    static func cny(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.numberStyle = .currency
        formatter.currencyCode = "CNY"
        formatter.currencySymbol = "¥"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "¥--"
    }

    static func compactCNY(_ amount: Decimal) -> String {
        let billion = Decimal(1_000_000_000)
        let million = Decimal(1_000_000)
        let thousand = Decimal(1_000)
        if amount > Decimal(string: "999900000000")! { return "¥999B+" }
        if amount >= billion { return compact(amount / billion, suffix: "B") }
        if amount >= Decimal(999_950_000) { return compact(amount / billion, suffix: "B") }
        if amount >= million { return compact(amount / million, suffix: "M") }
        if amount >= Decimal(999_950) { return compact(amount / million, suffix: "M") }
        if amount >= thousand { return compact(amount / thousand, suffix: "k") }
        return cny(amount).replacingOccurrences(of: ",", with: "")
    }

    private static func compact(_ amount: Decimal, suffix: String) -> String {
        var input = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 1, .plain)
        let number = NSDecimalNumber(decimal: rounded).stringValue
        return "¥\(number)\(suffix)"
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
