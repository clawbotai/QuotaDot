import Foundation

enum TokenHistoryScanner {
    private static let cacheVersion = 7
    private static let readChunkSize = 65_536
    private static let irrelevantLinePrefixLimit = 65_536
    private static let relevantLineHardLimit = 16 * 1_024 * 1_024

    static func scan(
        now: Date = .now,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        cacheURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TokenHistorySnapshot {
        var calendar = Calendar.autoupdatingCurrent
        calendar.timeZone = .autoupdatingCurrent
        let resolvedCacheURL = cacheURL ?? defaultCacheURL()
        let codexRoot = codexHome(homeDirectory: homeDirectory, environment: environment)
        let imports = loadImportedSessionRegistry(from: codexRoot)
        let files = discoverFiles(
            in: sourceDirectories(homeDirectory: homeDirectory, environment: environment),
            additionalClaudeFiles: imports.sourceFiles
        )
        let existingCache = loadCache(from: resolvedCacheURL, timeZone: calendar.timeZone)
        var updatedEntries: [String: CachedFileIndex] = [:]
        var unreadableFileCount = 0

        for file in files {
            do {
                let cached = existingCache.files[file.url.path]
                let entry = try index(file: file, resuming: cached)
                updatedEntries[file.url.path] = entry
                unreadableFileCount += entry.skippedRelevantLineCount
            } catch {
                unreadableFileCount += 1
            }
        }

        let cache = TokenHistoryCache(
            version: cacheVersion,
            timeZoneIdentifier: calendar.timeZone.identifier,
            files: updatedEntries
        )
        try? saveCache(cache, to: resolvedCacheURL)
        return aggregate(
            entries: Array(updatedEntries.values),
            scannedFileCount: files.count,
            unreadableFileCount: unreadableFileCount,
            now: now,
            calendar: calendar,
            excludedCodexSessionIds: imports.threadIds
        )
    }

    static func codexDailyUsage(from lines: [Data], calendar: Calendar = .current) -> [String: Int64] {
        var entry = CachedFileIndex.empty(source: .codex, inode: 0)
        for line in lines { indexCodexLine(line, into: &entry) }
        return aggregateCodex(
            entry: entry,
            baselineEventCount: 0,
            calendar: calendar,
            recentRange: nil
        ).daily
    }

    static func claudeDailyUsage(from lines: [Data], calendar: Calendar = .current) -> [String: Int64] {
        var messages: [String: CachedClaudeMessage] = [:]
        for line in lines {
            guard let record = TokenHistoryParser.claudeRecord(from: line) else { continue }
            merge(record.cached, into: &messages)
        }
        return aggregateClaude(messages: messages, calendar: calendar, recentRange: nil).daily
    }

    static func kimiDailyUsage(from lines: [Data], calendar: Calendar = .current) -> [String: Int64] {
        var entry = CachedFileIndex.empty(source: .kimi, inode: 0)
        for line in lines { indexKimiLine(line, into: &entry) }
        return aggregateKimi(entry: entry, calendar: calendar, recentRange: nil).daily
    }

    private static func index(file: HistoryFile, resuming cached: CachedFileIndex?) throws -> CachedFileIndex {
        if let cached, cached.isUnchanged(file) { return cached }

        let canResume = cached?.canResume(file) == true
        var entry = canResume ? cached! : CachedFileIndex.empty(source: file.source, inode: file.inode)
        let startOffset = canResume ? entry.byteOffset : 0
        let result = try forEachRelevantLine(
            in: file.url,
            source: file.source,
            startingAt: startOffset
        ) { line in
            switch file.source {
            case .codex: indexCodexLine(Data(line), into: &entry)
            case .claude: indexClaudeLine(Data(line), into: &entry)
            case .kimi: indexKimiLine(Data(line), into: &entry)
            }
        }

        entry.byteOffset = result.committedOffset
        entry.fileSize = file.fileSize
        entry.modifiedAt = file.modifiedAt
        entry.inode = file.inode
        entry.skippedRelevantLineCount += result.skippedRelevantLineCount
        return entry
    }

    private static func indexCodexLine(_ line: Data, into entry: inout CachedFileIndex) {
        if entry.ownerSessionId == nil, let metadata = TokenHistoryParser.codexSessionMetadata(from: line) {
            entry.ownerSessionId = metadata.sessionId
            entry.isSubagent = metadata.isSubagent
            entry.forkedFromId = metadata.forkedFromId
            entry.subagentBoundaryPassed = !metadata.isSubagent
            return
        }

        if TokenHistoryParser.isSubagentTurnBoundary(line), entry.isSubagent, !entry.subagentBoundaryPassed {
            entry.subagentBoundaryPassed = true
            return
        }

        guard let record = TokenHistoryParser.codexRecord(from: line) else { return }
        entry.codexEvents.append(CachedCodexEvent(
            timestamp: record.timestamp,
            cumulativeTotal: record.cumulativeTotal,
            lastTotal: record.lastTotal,
            isLive: entry.subagentBoundaryPassed
        ))
    }

    private static func indexClaudeLine(_ line: Data, into entry: inout CachedFileIndex) {
        guard let record = TokenHistoryParser.claudeRecord(from: line) else { return }
        merge(record.cached, into: &entry.claudeMessages)
    }

    private static func indexKimiLine(_ line: Data, into entry: inout CachedFileIndex) {
        guard let record = TokenHistoryParser.kimiRecord(from: line) else { return }
        entry.kimiEvents.append(CachedKimiEvent(
            timestampMilliseconds: record.timestampMilliseconds,
            tokens: record.totalTokens
        ))
    }

    private static func aggregate(
        entries: [CachedFileIndex],
        scannedFileCount: Int,
        unreadableFileCount: Int,
        now: Date,
        calendar: Calendar,
        excludedCodexSessionIds: Set<String>
    ) -> TokenHistorySnapshot {
        let canonicalCodex = canonicalCodexEntries(entries.filter {
            $0.source == .codex && !excludedCodexSessionIds.contains($0.ownerSessionId ?? "")
        })
        let codexByOwner = Dictionary(uniqueKeysWithValues: canonicalCodex.compactMap { entry in
            entry.ownerSessionId.map { ($0, entry) }
        })
        var byProvider: [HistorySource: [String: Int64]] = [:]
        var recentUsage: [TimedProviderTokenUsage] = []
        let recentCutoff = calendar.date(byAdding: .day, value: -8, to: now)
            ?? now.addingTimeInterval(-8 * 24 * 60 * 60)
        let recentRange = recentCutoff...now

        for entry in canonicalCodex {
            var baselineEventCount = 0
            if !entry.isSubagent,
               let parentId = entry.forkedFromId,
               let parent = codexByOwner[parentId] {
                baselineEventCount = longestCommonPrefix(entry.codexEvents, parent.codexEvents)
            }
            let usage = aggregateCodex(
                entry: entry,
                baselineEventCount: baselineEventCount,
                calendar: calendar,
                recentRange: recentRange
            )
            merge(usage.daily, into: &byProvider[.codex, default: [:]])
            recentUsage.append(contentsOf: usage.recent.map {
                TimedProviderTokenUsage(providerId: HistorySource.codex.rawValue, timestamp: $0.timestamp, tokens: $0.tokens)
            })
        }

        var globalClaudeMessages: [String: CachedClaudeMessage] = [:]
        for entry in entries where entry.source == .claude {
            for message in entry.claudeMessages.values {
                merge(message, into: &globalClaudeMessages)
            }
        }
        let claudeUsage = aggregateClaude(
            messages: globalClaudeMessages,
            calendar: calendar,
            recentRange: recentRange
        )
        byProvider[.claude] = claudeUsage.daily
        recentUsage.append(contentsOf: claudeUsage.recent.map {
            TimedProviderTokenUsage(providerId: HistorySource.claude.rawValue, timestamp: $0.timestamp, tokens: $0.tokens)
        })

        var kimiDaily: [String: Int64] = [:]
        for entry in entries where entry.source == .kimi {
            let usage = aggregateKimi(entry: entry, calendar: calendar, recentRange: recentRange)
            merge(usage.daily, into: &kimiDaily)
            recentUsage.append(contentsOf: usage.recent.map {
                TimedProviderTokenUsage(providerId: HistorySource.kimi.rawValue, timestamp: $0.timestamp, tokens: $0.tokens)
            })
        }
        byProvider[.kimi] = kimiDaily

        return makeSnapshot(
            byProvider: byProvider,
            recentUsage: recentUsage.sorted { $0.timestamp < $1.timestamp },
            scannedFileCount: scannedFileCount,
            unreadableFileCount: unreadableFileCount,
            now: now,
            calendar: calendar
        )
    }

    private static func canonicalCodexEntries(_ entries: [CachedFileIndex]) -> [CachedFileIndex] {
        var bySession: [String: CachedFileIndex] = [:]
        var withoutSession: [CachedFileIndex] = []
        for entry in entries {
            guard let sessionId = entry.ownerSessionId else {
                withoutSession.append(entry)
                continue
            }
            if let current = bySession[sessionId] {
                if entry.codexEvents.count > current.codexEvents.count
                    || (entry.codexEvents.count == current.codexEvents.count && entry.fileSize > current.fileSize) {
                    bySession[sessionId] = entry
                }
            } else {
                bySession[sessionId] = entry
            }
        }
        return Array(bySession.values) + withoutSession
    }

    private static func longestCommonPrefix(_ child: [CachedCodexEvent], _ parent: [CachedCodexEvent]) -> Int {
        let upperBound = min(child.count, parent.count)
        var index = 0
        while index < upperBound,
              child[index].cumulativeTotal == parent[index].cumulativeTotal {
            index += 1
        }
        return index
    }

    private static func aggregateCodex(
        entry: CachedFileIndex,
        baselineEventCount: Int,
        calendar: Calendar,
        recentRange: ClosedRange<Date>?
    ) -> ProviderHistoryAggregation {
        var previousTotal: Int64 = 0
        var daily: [String: Int64] = [:]
        var recent: [TimedTokenContribution] = []

        for (index, event) in entry.codexEvents.enumerated() {
            let shouldCount = event.isLive && index >= baselineEventCount
            let delta: Int64
            if event.cumulativeTotal >= previousTotal {
                delta = event.cumulativeTotal - previousTotal
            } else {
                delta = event.lastTotal ?? event.cumulativeTotal
            }
            previousTotal = event.cumulativeTotal
            guard shouldCount, delta > 0,
                  let date = TokenHistoryParser.date(from: event.timestamp) else { continue }
            daily[dayKey(for: date, calendar: calendar), default: 0] += delta
            if recentRange?.contains(date) == true {
                recent.append(TimedTokenContribution(timestamp: date, tokens: delta))
            }
        }
        return ProviderHistoryAggregation(daily: daily, recent: recent)
    }

    private static func aggregateClaude(
        messages: [String: CachedClaudeMessage],
        calendar: Calendar,
        recentRange: ClosedRange<Date>?
    ) -> ProviderHistoryAggregation {
        var daily: [String: Int64] = [:]
        var recent: [TimedTokenContribution] = []
        for message in messages.values {
            guard message.total > 0,
                  let date = TokenHistoryParser.date(from: message.timestamp) else { continue }
            daily[dayKey(for: date, calendar: calendar), default: 0] += message.total
            if recentRange?.contains(date) == true {
                recent.append(TimedTokenContribution(timestamp: date, tokens: message.total))
            }
        }
        return ProviderHistoryAggregation(daily: daily, recent: recent)
    }

    private static func aggregateKimi(
        entry: CachedFileIndex,
        calendar: Calendar,
        recentRange: ClosedRange<Date>?
    ) -> ProviderHistoryAggregation {
        var daily: [String: Int64] = [:]
        var recent: [TimedTokenContribution] = []
        for event in entry.kimiEvents where event.tokens > 0 {
            let date = Date(timeIntervalSince1970: event.timestampMilliseconds / 1_000)
            daily[dayKey(for: date, calendar: calendar), default: 0] += event.tokens
            if recentRange?.contains(date) == true {
                recent.append(TimedTokenContribution(timestamp: date, tokens: event.tokens))
            }
        }
        return ProviderHistoryAggregation(daily: daily, recent: recent)
    }

    private static func makeSnapshot(
        byProvider: [HistorySource: [String: Int64]],
        recentUsage: [TimedProviderTokenUsage],
        scannedFileCount: Int,
        unreadableFileCount: Int,
        now: Date,
        calendar: Calendar
    ) -> TokenHistorySnapshot {
        let allDayKeys = Set(byProvider.values.flatMap(\.keys)).sorted()
        let dailyUsage = allDayKeys.compactMap { key -> DailyTokenUsage? in
            guard let date = date(fromDayKey: key, calendar: calendar) else { return nil }
            return DailyTokenUsage(
                date: date,
                tokensByProvider: Dictionary(uniqueKeysWithValues: HistorySource.allCases.map {
                    ($0.rawValue, byProvider[$0]?[key] ?? 0)
                })
            )
        }

        let today = calendar.startOfDay(for: now)
        let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let startOfMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
        let todayKey = dayKey(for: today, calendar: calendar)
        let providerUsage = HistorySource.allCases.map { source in
            let datedValues = (byProvider[source] ?? [:]).compactMap { key, tokens -> (Date, Int64)? in
                date(fromDayKey: key, calendar: calendar).map { ($0, tokens) }
            }
            return ProviderTokenUsage(
                id: source.rawValue,
                displayName: source.displayName,
                totalTokens: datedValues.reduce(0) { $0 + $1.1 },
                todayTokens: byProvider[source]?[todayKey] ?? 0,
                monthTokens: datedValues.filter { $0.0 >= startOfMonth && $0.0 <= today }.reduce(0) { $0 + $1.1 },
                weekTokens: datedValues.filter { $0.0 >= startOfWeek && $0.0 <= today }.reduce(0) { $0 + $1.1 },
                firstActivityDate: datedValues.map(\.0).min()
            )
        }

        return TokenHistorySnapshot(
            totalTokens: providerUsage.reduce(0) { $0 + $1.totalTokens },
            todayTokens: providerUsage.reduce(0) { $0 + $1.todayTokens },
            monthTokens: providerUsage.reduce(0) { $0 + $1.monthTokens },
            weekTokens: providerUsage.reduce(0) { $0 + $1.weekTokens },
            providers: providerUsage,
            dailyUsage: dailyUsage,
            recentUsage: recentUsage,
            scannedFileCount: scannedFileCount,
            unreadableFileCount: unreadableFileCount,
            firstActivityDate: dailyUsage.first?.date,
            generatedAt: now
        )
    }

    private static func merge(_ source: [String: Int64], into destination: inout [String: Int64]) {
        for (day, tokens) in source { destination[day, default: 0] += tokens }
    }

    private static func merge(_ message: CachedClaudeMessage, into messages: inout [String: CachedClaudeMessage]) {
        guard let current = messages[message.id] else {
            messages[message.id] = message
            return
        }
        messages[message.id] = current.merged(with: message)
    }

    private static func sourceDirectories(
        homeDirectory: URL,
        environment: [String: String]
    ) -> [HistorySourceDirectory] {
        let codexHome = codexHome(homeDirectory: homeDirectory, environment: environment)
        let claudeHome = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".claude", isDirectory: true)
        let kimiHome = environment["KIMI_CODE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".kimi-code", isDirectory: true)
        return [
            HistorySourceDirectory(source: .codex, url: codexHome.appendingPathComponent("sessions", isDirectory: true)),
            HistorySourceDirectory(source: .codex, url: codexHome.appendingPathComponent("archived_sessions", isDirectory: true)),
            HistorySourceDirectory(source: .claude, url: claudeHome.appendingPathComponent("projects", isDirectory: true)),
            HistorySourceDirectory(source: .kimi, url: kimiHome.appendingPathComponent("sessions", isDirectory: true))
        ]
    }

    private static func codexHome(homeDirectory: URL, environment: [String: String]) -> URL {
        environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    private static func discoverFiles(
        in directories: [HistorySourceDirectory],
        additionalClaudeFiles: Set<URL>
    ) -> [HistoryFile] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        var resultByPath: [String: HistoryFile] = [:]
        for directory in directories {
            guard let enumerator = manager.enumerator(
                at: directory.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                guard let file = historyFile(at: url, source: directory.source, keys: keys, manager: manager) else { continue }
                resultByPath[url.standardizedFileURL.path] = file
            }
        }
        for url in additionalClaudeFiles where url.pathExtension.lowercased() == "jsonl" {
            guard let file = historyFile(at: url, source: .claude, keys: keys, manager: manager) else { continue }
            resultByPath[url.standardizedFileURL.path] = file
        }
        return Array(resultByPath.values)
    }

    private static func historyFile(
        at url: URL,
        source: HistorySource,
        keys: Set<URLResourceKey>,
        manager: FileManager
    ) -> HistoryFile? {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              let fileSize = values.fileSize,
              let modifiedAt = values.contentModificationDate else { return nil }
        let attributes = try? manager.attributesOfItem(atPath: url.path)
        let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        return HistoryFile(
            source: source,
            url: url,
            fileSize: Int64(fileSize),
            modifiedAt: modifiedAt.timeIntervalSince1970,
            inode: inode
        )
    }

    private static func loadImportedSessionRegistry(from codexHome: URL) -> ImportedSessionRegistry {
        let manager = FileManager.default
        let urls = [
            codexHome.appendingPathComponent("external_agent_session_imports.json"),
            codexHome.appendingPathComponent("claude-cowork-import-history.json")
        ]
        var registry = ImportedSessionRegistry()

        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                let threadId = dictionary["imported_thread_id"] as? String
                    ?? dictionary["importedThreadId"] as? String
                let sourcePath = dictionary["source_path"] as? String
                    ?? dictionary["sourcePath"] as? String
                if let threadId { registry.threadIds.insert(threadId) }
                if let sourcePath, manager.fileExists(atPath: sourcePath) {
                    registry.sourceFiles.insert(URL(fileURLWithPath: sourcePath).standardizedFileURL)
                }
                for nested in dictionary.values { visit(nested) }
            } else if let array = value as? [Any] {
                for nested in array { visit(nested) }
            }
        }

        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            visit(object)
        }
        return registry
    }

    private static func forEachRelevantLine(
        in url: URL,
        source: HistorySource,
        startingAt startOffset: Int64,
        body: (Data.SubSequence) -> Void
    ) throws -> LineScanResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(max(startOffset, 0)))

        var buffer = Data()
        var bufferStartOffset = startOffset
        var readOffset = startOffset
        var committedOffset = startOffset
        var discardingLine = false
        var skippedRelevantLineCount = 0

        while let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty {
            let chunkStartOffset = readOffset
            readOffset += Int64(chunk.count)
            var segment = chunk[chunk.startIndex..<chunk.endIndex]

            if discardingLine {
                guard let newline = segment.firstIndex(of: 0x0A) else { continue }
                let afterNewline = segment.index(after: newline)
                committedOffset = chunkStartOffset + Int64(chunk.distance(from: chunk.startIndex, to: afterNewline))
                bufferStartOffset = committedOffset
                segment = segment[afterNewline..<segment.endIndex]
                discardingLine = false
            }

            buffer.append(contentsOf: segment)
            var lineStart = buffer.startIndex
            while let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
                let line = buffer[lineStart..<newline]
                if isCompleteLineRelevant(line, source: source) { body(line) }
                lineStart = buffer.index(after: newline)
                committedOffset = bufferStartOffset + Int64(buffer.distance(from: buffer.startIndex, to: lineStart))
                if lineStart == buffer.endIndex { break }
            }
            if lineStart > buffer.startIndex {
                let removed = buffer.distance(from: buffer.startIndex, to: lineStart)
                buffer.removeSubrange(buffer.startIndex..<lineStart)
                bufferStartOffset += Int64(removed)
            }

            if buffer.count > irrelevantLinePrefixLimit {
                let relevant = isPotentiallyRelevant(buffer, source: source)
                if !relevant || buffer.count > relevantLineHardLimit {
                    if relevant { skippedRelevantLineCount += 1 }
                    buffer.removeAll(keepingCapacity: false)
                    discardingLine = true
                }
            }
        }

        // Active JSONL writers may leave a partial final line. Keep the cursor at
        // that line's beginning so the next incremental scan can read it once.
        return LineScanResult(
            committedOffset: committedOffset,
            skippedRelevantLineCount: skippedRelevantLineCount
        )
    }

    private static func isPotentiallyRelevant(_ data: Data, source: HistorySource) -> Bool {
        switch source {
        case .codex:
            return contains(data, "session_meta")
                || contains(data, "inter_agent_communication_metadata")
                || contains(data, "event_msg") && contains(data, "token_count")
        case .claude:
            return contains(data, "\"type\":\"assistant\"")
                || contains(data, "\"role\":\"assistant\"") && contains(data, "\"message\"")
        case .kimi:
            return (contains(data, "\"type\":\"turn.step.completed\"")
                || contains(data, "\"type\":\"usage.record\""))
                && contains(data, "\"usage\"")
        }
    }

    private static func isCompleteLineRelevant(_ data: Data.SubSequence, source: HistorySource) -> Bool {
        switch source {
        case .codex:
            return contains(data, "session_meta")
                || contains(data, "inter_agent_communication_metadata")
                || contains(data, "event_msg") && contains(data, "token_count")
        case .claude:
            return contains(data, "\"type\":\"assistant\"") && contains(data, "\"usage\"")
        case .kimi:
            return (contains(data, "\"type\":\"turn.step.completed\"")
                || contains(data, "\"type\":\"usage.record\""))
                && contains(data, "\"usage\"")
        }
    }

    private static func contains(_ data: Data.SubSequence, _ text: String) -> Bool {
        data.range(of: Data(text.utf8)) != nil
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private static func defaultCacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("QuotaDot", isDirectory: true)
            .appendingPathComponent("token-history-cache.json")
    }

    private static func loadCache(from url: URL, timeZone: TimeZone) -> TokenHistoryCache {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(TokenHistoryCache.self, from: data),
              cache.version == cacheVersion,
              cache.timeZoneIdentifier == timeZone.identifier else {
            return TokenHistoryCache(version: cacheVersion, timeZoneIdentifier: timeZone.identifier, files: [:])
        }
        return cache
    }

    private static func saveCache(_ cache: TokenHistoryCache, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(cache)
        try data.write(to: url, options: .atomic)

        do {
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            if attributes?[.type] as? FileAttributeType == .typeRegular {
                try? manager.removeItem(at: url)
            }
            throw error
        }
    }
}

enum TokenHistoryParser {
    struct CodexRecord: Equatable {
        let timestamp: String
        let cumulativeTotal: Int64
        let lastTotal: Int64?
    }

    struct CodexSessionMetadata: Equatable {
        let sessionId: String
        let isSubagent: Bool
        let forkedFromId: String?
    }

    struct ClaudeRecord: Equatable {
        let timestamp: String
        let id: String
        let inputTokens: Int64
        let cacheCreationTokens: Int64
        let cacheReadTokens: Int64
        let outputTokens: Int64

        fileprivate var cached: CachedClaudeMessage {
            CachedClaudeMessage(
                id: id,
                timestamp: timestamp,
                inputTokens: inputTokens,
                cacheCreationTokens: cacheCreationTokens,
                cacheReadTokens: cacheReadTokens,
                outputTokens: outputTokens
            )
        }
    }

    struct KimiRecord: Equatable {
        let timestampMilliseconds: Double
        let totalTokens: Int64
    }

    static func codexRecord(from line: Data) -> CodexRecord? {
        guard let object = object(from: line),
              object["type"] as? String == "event_msg",
              let timestamp = object["timestamp"] as? String,
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any],
              let total = number(usage["total_tokens"]) else { return nil }
        let lastUsage = info["last_token_usage"] as? [String: Any]
        return CodexRecord(
            timestamp: timestamp,
            cumulativeTotal: total,
            lastTotal: number(lastUsage?["total_tokens"])
        )
    }

    static func codexSessionMetadata(from line: Data) -> CodexSessionMetadata? {
        guard let object = object(from: line),
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let sessionId = payload["id"] as? String else { return nil }
        let source = payload["source"] as? [String: Any]
        let isSubagent = payload["parent_thread_id"] != nil
            && payload["agent_path"] != nil
            || source?["subagent"] != nil
        return CodexSessionMetadata(
            sessionId: sessionId,
            isSubagent: isSubagent,
            forkedFromId: payload["forked_from_id"] as? String
        )
    }

    static func isSubagentTurnBoundary(_ line: Data) -> Bool {
        guard let object = object(from: line),
              object["type"] as? String == "inter_agent_communication_metadata",
              let payload = object["payload"] as? [String: Any] else { return false }
        return payload["trigger_turn"] as? Bool == true
    }

    static func claudeRecord(from line: Data) -> ClaudeRecord? {
        guard let object = object(from: line),
              object["type"] as? String == "assistant",
              let timestamp = object["timestamp"] as? String,
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return nil }
        guard let id = message["id"] as? String
            ?? object["requestId"] as? String
            ?? object["uuid"] as? String else { return nil }
        return ClaudeRecord(
            timestamp: timestamp,
            id: id,
            inputTokens: number(usage["input_tokens"]) ?? 0,
            cacheCreationTokens: number(usage["cache_creation_input_tokens"]) ?? 0,
            cacheReadTokens: number(usage["cache_read_input_tokens"]) ?? 0,
            outputTokens: number(usage["output_tokens"]) ?? 0
        )
    }

    static func kimiRecord(from line: Data) -> KimiRecord? {
        guard let object = object(from: line),
              let type = object["type"] as? String,
              type == "turn.step.completed" || type == "usage.record",
              let timestamp = decimal(object["time"] ?? object["at"]),
              let usage = object["usage"] as? [String: Any] else { return nil }
        let total = ["inputOther", "output", "inputCacheRead", "inputCacheCreation"]
            .reduce(Int64(0)) { $0 + (number(usage[$1]) ?? 0) }
        guard total > 0 else { return nil }
        return KimiRecord(timestampMilliseconds: timestamp, totalTokens: total)
    }

    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func object(from line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private static func number(_ value: Any?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private static func decimal(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

private enum HistorySource: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case kimi

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .kimi: "Kimi"
        }
    }
}

private struct HistorySourceDirectory {
    let source: HistorySource
    let url: URL
}

private struct HistoryFile {
    let source: HistorySource
    let url: URL
    let fileSize: Int64
    let modifiedAt: TimeInterval
    let inode: UInt64
}

private struct ImportedSessionRegistry {
    var threadIds: Set<String> = []
    var sourceFiles: Set<URL> = []
}

private struct ProviderHistoryAggregation {
    let daily: [String: Int64]
    let recent: [TimedTokenContribution]
}

private struct TimedTokenContribution {
    let timestamp: Date
    let tokens: Int64
}

private struct LineScanResult {
    let committedOffset: Int64
    let skippedRelevantLineCount: Int
}

private struct TokenHistoryCache: Codable {
    let version: Int
    let timeZoneIdentifier: String
    let files: [String: CachedFileIndex]
}

private struct CachedFileIndex: Codable {
    let source: HistorySource
    var inode: UInt64
    var fileSize: Int64
    var modifiedAt: TimeInterval
    var byteOffset: Int64
    var ownerSessionId: String?
    var isSubagent: Bool
    var forkedFromId: String?
    var subagentBoundaryPassed: Bool
    var codexEvents: [CachedCodexEvent]
    var claudeMessages: [String: CachedClaudeMessage]
    var kimiEvents: [CachedKimiEvent]
    var skippedRelevantLineCount: Int

    static func empty(source: HistorySource, inode: UInt64) -> CachedFileIndex {
        CachedFileIndex(
            source: source,
            inode: inode,
            fileSize: 0,
            modifiedAt: 0,
            byteOffset: 0,
            ownerSessionId: nil,
            isSubagent: false,
            forkedFromId: nil,
            subagentBoundaryPassed: true,
            codexEvents: [],
            claudeMessages: [:],
            kimiEvents: [],
            skippedRelevantLineCount: 0
        )
    }

    func isUnchanged(_ file: HistoryFile) -> Bool {
        source == file.source
            && inode == file.inode
            && fileSize == file.fileSize
            && byteOffset == file.fileSize
            && abs(modifiedAt - file.modifiedAt) < 0.001
    }

    func canResume(_ file: HistoryFile) -> Bool {
        source == file.source
            && inode == file.inode
            && file.fileSize >= byteOffset
            && (file.fileSize > fileSize || abs(modifiedAt - file.modifiedAt) < 0.001)
    }
}

private struct CachedCodexEvent: Codable, Equatable {
    let timestamp: String
    let cumulativeTotal: Int64
    let lastTotal: Int64?
    let isLive: Bool
}

private struct CachedClaudeMessage: Codable {
    let id: String
    let timestamp: String
    let inputTokens: Int64
    let cacheCreationTokens: Int64
    let cacheReadTokens: Int64
    let outputTokens: Int64

    var total: Int64 { inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens }

    func merged(with other: CachedClaudeMessage) -> CachedClaudeMessage {
        CachedClaudeMessage(
            id: id,
            timestamp: min(timestamp, other.timestamp),
            inputTokens: max(inputTokens, other.inputTokens),
            cacheCreationTokens: max(cacheCreationTokens, other.cacheCreationTokens),
            cacheReadTokens: max(cacheReadTokens, other.cacheReadTokens),
            outputTokens: max(outputTokens, other.outputTokens)
        )
    }
}

private struct CachedKimiEvent: Codable {
    let timestampMilliseconds: Double
    let tokens: Int64
}
