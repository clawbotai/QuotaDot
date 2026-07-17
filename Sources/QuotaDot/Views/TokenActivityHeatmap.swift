import SwiftUI

struct TokenActivityHeatmap: View {
    let dailyUsage: [DailyTokenUsage]
    let language: LanguageSettings
    @Binding var granularity: TokenActivityGranularity

    private let idealCellSize: CGFloat = 12
    private let minimumCellSize: CGFloat = 9
    private let cellSpacing: CGFloat = 3.5
    private let trailingSafetyInset: CGFloat = 14
    private var calendar: Calendar { Calendar.autoupdatingCurrent }

    var body: some View {
        let model = CalendarHeatmapModel(
            dailyUsage: dailyUsage,
            granularity: granularity,
            calendar: calendar
        )

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Text(language.text("history.activity.title"))
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Picker("", selection: $granularity) {
                    ForEach(TokenActivityGranularity.allCases) { item in
                        Text(language.text("history.activity.\(item.rawValue)"))
                            .tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 235)
            }

            GeometryReader { geometry in
                let cellSize = resolvedCellSize(
                    availableWidth: geometry.size.width,
                    weekCount: model.weekCount
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    calendarGrid(model: model, cellSize: cellSize)
                        .padding(.trailing, trailingSafetyInset)
                        .padding(.bottom, 2)
                }
            }
            .frame(height: calendarAreaHeight, alignment: .top)

            HStack(spacing: 7) {
                Text(language.text("history.activity.less"))
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color(forLevel: level))
                        .frame(width: 12, height: 12)
                }
                Text(language.text("history.activity.more"))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(22)
        .quotaContentGlass(cornerRadius: 22)
    }

    private func calendarGrid(model: CalendarHeatmapModel, cellSize: CGFloat) -> some View {
        let rows = Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: 7)
        let width = CGFloat(model.weekCount) * (cellSize + cellSpacing) - cellSpacing

        return VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .leading) {
                ForEach(model.monthMarkers) { marker in
                    Text(monthLabel(marker.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .offset(x: CGFloat(marker.weekIndex) * (cellSize + cellSpacing))
                }
            }
            .frame(width: width, height: 18, alignment: .leading)

            LazyHGrid(rows: rows, alignment: .top, spacing: cellSpacing) {
                ForEach(model.cells) { cell in
                    RoundedRectangle(cornerRadius: min(3.5, cellSize * 0.30), style: .continuous)
                        .fill(cell.date > model.today ? color(forLevel: 0) : color(forLevel: model.level(for: cell.value)))
                        .frame(width: cellSize, height: cellSize)
                        .help(helpText(for: cell, model: model))
                        .accessibilityLabel(helpText(for: cell, model: model))
                }
            }
            .frame(width: width, alignment: .leading)
        }
    }

    private var calendarAreaHeight: CGFloat {
        18 + 8 + idealCellSize * 7 + cellSpacing * 6 + 2
    }

    private func resolvedCellSize(availableWidth: CGFloat, weekCount: Int) -> CGFloat {
        let columns = CGFloat(max(weekCount, 1))
        let gaps = CGFloat(max(weekCount - 1, 0)) * cellSpacing
        let usableWidth = max(availableWidth - trailingSafetyInset - gaps, 0)
        let fitted = (usableWidth / columns * 2).rounded(.down) / 2
        return min(idealCellSize, max(minimumCellSize, fitted))
    }

    private func color(forLevel level: Int) -> Color {
        switch level {
        case 1: .blue.opacity(0.24)
        case 2: .blue.opacity(0.42)
        case 3: .blue.opacity(0.64)
        case 4: .blue.opacity(0.88)
        default: Color(nsColor: .separatorColor).opacity(0.24)
        }
    }

    private func monthLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = language.language.locale
        formatter.dateFormat = language.language == .simplifiedChinese ? "M月" : "MMM"
        return formatter.string(from: date)
    }

    private func helpText(for cell: CalendarHeatmapModel.Cell, model: CalendarHeatmapModel) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = language.language.locale
        dateFormatter.dateStyle = .medium
        let count = QuotaFormatters.tokenCount(cell.value, language: language.language, compact: false)

        switch granularity {
        case .daily:
            return "\(dateFormatter.string(from: cell.date)) · \(count) Token"
        case .weekly:
            let interval = calendar.dateInterval(of: .weekOfYear, for: cell.date)
            let start = interval?.start ?? cell.date
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            return "\(dateFormatter.string(from: start)) – \(dateFormatter.string(from: end)) · \(count) Token"
        case .cumulative:
            return "\(language.text("history.activity.through", dateFormatter.string(from: cell.date))) · \(count) Token"
        }
    }
}

private struct CalendarHeatmapModel {
    struct Cell: Identifiable {
        let date: Date
        let value: Int64
        var id: Date { date }
    }

    struct MonthMarker: Identifiable {
        let date: Date
        let weekIndex: Int
        var id: Date { date }
    }

    let cells: [Cell]
    let monthMarkers: [MonthMarker]
    let weekCount: Int
    let today: Date
    private let positiveValues: [Int64]

    init(dailyUsage: [DailyTokenUsage], granularity: TokenActivityGranularity, calendar: Calendar) {
        let resolvedToday = calendar.startOfDay(for: .now)
        today = resolvedToday
        let firstVisibleDay = calendar.date(byAdding: .day, value: -364, to: resolvedToday) ?? resolvedToday
        let gridStart = calendar.dateInterval(of: .weekOfYear, for: firstVisibleDay)?.start ?? firstVisibleDay
        let currentWeekEnd = calendar.dateInterval(of: .weekOfYear, for: resolvedToday)?.end
        let gridEnd = currentWeekEnd.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) } ?? resolvedToday
        let rawValues = Dictionary(uniqueKeysWithValues: dailyUsage.map { (calendar.startOfDay(for: $0.date), $0.totalTokens) })
        let visibleDates = Self.dates(from: gridStart, through: gridEnd, calendar: calendar)
        let transformed = Self.transformedValues(
            for: visibleDates,
            allUsage: dailyUsage,
            rawValues: rawValues,
            granularity: granularity,
            calendar: calendar
        )
        cells = visibleDates.map { Cell(date: $0, value: $0 <= resolvedToday ? transformed[$0, default: 0] : 0) }
        positiveValues = cells.map(\.value).filter { $0 > 0 }.sorted()
        weekCount = max(Int(ceil(Double(cells.count) / 7.0)), 1)
        monthMarkers = Self.markers(from: gridStart, through: gridEnd, calendar: calendar)
    }

    func level(for value: Int64) -> Int {
        guard value > 0, !positiveValues.isEmpty else { return 0 }
        if positiveValues.count < 5 {
            let maximum = max(positiveValues.last ?? 1, 1)
            return min(max(Int(ceil(Double(value) / Double(maximum) * 4)), 1), 4)
        }
        let rank = positiveValues.partitioningIndex { $0 > value }
        let percentile = Double(rank) / Double(positiveValues.count)
        return min(max(Int(ceil(percentile * 4)), 1), 4)
    }

    private static func transformedValues(
        for visibleDates: [Date],
        allUsage: [DailyTokenUsage],
        rawValues: [Date: Int64],
        granularity: TokenActivityGranularity,
        calendar: Calendar
    ) -> [Date: Int64] {
        switch granularity {
        case .daily:
            return rawValues
        case .weekly:
            var weeklyTotals: [Date: Int64] = [:]
            for usage in allUsage {
                let day = calendar.startOfDay(for: usage.date)
                let week = calendar.dateInterval(of: .weekOfYear, for: day)?.start ?? day
                weeklyTotals[week, default: 0] += usage.totalTokens
            }
            return Dictionary(uniqueKeysWithValues: visibleDates.map { date in
                let week = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
                return (date, weeklyTotals[week, default: 0])
            })
        case .cumulative:
            let sortedUsage = allUsage.sorted { $0.date < $1.date }
            var running: Int64 = 0
            var index = 0
            var result: [Date: Int64] = [:]
            for date in visibleDates {
                while index < sortedUsage.count && calendar.startOfDay(for: sortedUsage[index].date) <= date {
                    running += sortedUsage[index].totalTokens
                    index += 1
                }
                result[date] = running
            }
            return result
        }
    }

    private static func dates(from start: Date, through end: Date, calendar: Calendar) -> [Date] {
        var result: [Date] = []
        var cursor = start
        while cursor <= end {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return result
    }

    private static func markers(from start: Date, through end: Date, calendar: Calendar) -> [MonthMarker] {
        var markers: [MonthMarker] = [MonthMarker(date: start, weekIndex: 0)]
        var cursor = calendar.dateInterval(of: .month, for: start)?.end ?? start
        while cursor <= end {
            let days = calendar.dateComponents([.day], from: start, to: cursor).day ?? 0
            markers.append(MonthMarker(date: cursor, weekIndex: max(days / 7, 0)))
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return markers
    }
}

private extension Array where Element: Comparable {
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = startIndex
        var high = endIndex
        while low < high {
            let middle = index(low, offsetBy: distance(from: low, to: high) / 2)
            if predicate(self[middle]) { high = middle } else { low = index(after: middle) }
        }
        return low
    }
}
