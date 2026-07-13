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

    @MainActor static func relativeReset(from date: Date, language: LanguageSettings, now: Date = .now) -> String {
        let seconds = max(date.timeIntervalSince(now), 0)
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours >= 24 { return language.text("time.daysHours", hours / 24, hours % 24) }
        if hours > 0 { return language.text("time.hoursMinutes", hours, minutes) }
        return language.text("time.minutes", minutes)
    }
}
