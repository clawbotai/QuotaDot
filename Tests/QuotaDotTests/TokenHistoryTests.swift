import Foundation
import Testing
@testable import QuotaDot

struct TokenHistoryTests {
    @Test func codexUsesCumulativeDeltasAndIgnoresDuplicates() throws {
        let lines = [
            sessionMetadata(id: "root"),
            codexEvent(timestamp: "2026-07-17T01:00:00.000Z", cumulative: 100, last: 100),
            codexEvent(timestamp: "2026-07-17T01:01:00.000Z", cumulative: 150, last: 50),
            codexEvent(timestamp: "2026-07-17T01:02:00.000Z", cumulative: 150, last: 50)
        ]

        let usage = TokenHistoryScanner.codexDailyUsage(from: lines, calendar: utcCalendar)
        #expect(usage["2026-07-17"] == 150)
    }

    @Test func codexSubagentSkipsInheritedParentPrefix() throws {
        let lines = [
            sessionMetadata(id: "child", parent: "root", agentPath: "/root/audit"),
            codexEvent(timestamp: "2026-07-17T01:00:00.000Z", cumulative: 100, last: 100),
            codexEvent(timestamp: "2026-07-17T01:01:00.000Z", cumulative: 200, last: 100),
            data(#"{"timestamp":"2026-07-17T01:01:30.000Z","type":"inter_agent_communication_metadata","payload":{"trigger_turn":true}}"#),
            codexEvent(timestamp: "2026-07-17T01:02:00.000Z", cumulative: 250, last: 50),
            codexEvent(timestamp: "2026-07-17T01:03:00.000Z", cumulative: 250, last: 50),
            codexEvent(timestamp: "2026-07-17T01:04:00.000Z", cumulative: 300, last: 50)
        ]

        let usage = TokenHistoryScanner.codexDailyUsage(from: lines, calendar: utcCalendar)
        #expect(usage["2026-07-17"] == 100)
    }

    @Test func legacyThreadSourceLabelAloneDoesNotHideAWholeSession() throws {
        let metadata = json([
            "timestamp": "2026-07-17T00:00:00.000Z",
            "type": "session_meta",
            "payload": [
                "id": "legacy-root",
                "source": "vscode",
                "thread_source": "subagent"
            ]
        ])
        let usage = TokenHistoryScanner.codexDailyUsage(
            from: [metadata, codexEvent(timestamp: "2026-07-17T01:00:00.000Z", cumulative: 100, last: 100)],
            calendar: utcCalendar
        )
        #expect(usage["2026-07-17"] == 100)
    }

    @Test func claudeDeduplicatesStreamingFragmentsAndUsesTopLevelUsageOnly() throws {
        let first = claudeEvent(id: "msg-1", input: 10, cacheCreation: 20, cacheRead: 30, output: 40)
        let repeated = claudeEvent(id: "msg-1", input: 10, cacheCreation: 20, cacheRead: 30, output: 40)
        let updated = claudeEvent(id: "msg-1", input: 12, cacheCreation: 20, cacheRead: 35, output: 41)
        let usage = TokenHistoryScanner.claudeDailyUsage(
            from: [first, repeated, updated],
            calendar: utcCalendar
        )

        #expect(usage["2026-07-17"] == 108)
    }

    @Test func kimiCountsCompletedStepUsageWithoutReadingConversationText() throws {
        let usage = TokenHistoryScanner.kimiDailyUsage(
            from: [
                kimiEvent(timestamp: "2026-07-17T03:00:00Z", input: 10, cacheCreation: 20, cacheRead: 30, output: 40),
                data(#"{"type":"assistant.delta","time":1784257201000,"delta":"ignored text"}"#)
            ],
            calendar: utcCalendar
        )

        #expect(usage["2026-07-17"] == 100)
    }

    @Test func scanResumesAnAppendedFileWithoutDoubleCounting() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let session = fixture.codexSessions.appendingPathComponent("root.jsonl")
        try writeLines([
            sessionMetadata(id: "root"),
            codexEvent(timestamp: "2026-07-17T01:00:00.000Z", cumulative: 100, last: 100)
        ], to: session)

        let first = try fixture.scan()
        #expect(first.totalTokens == 100)

        try appendLines([
            codexEvent(timestamp: "2026-07-17T01:01:00.000Z", cumulative: 150, last: 50)
        ], to: session)
        let second = try fixture.scan()
        #expect(second.totalTokens == 150)
    }

    @Test func scanRestrictsTheLocalIndexToTheCurrentUser() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        try writeLines([
            sessionMetadata(id: "private-cache"),
            codexEvent(timestamp: "2026-07-17T01:00:00.000Z", cumulative: 100, last: 100)
        ], to: fixture.codexSessions.appendingPathComponent("private-cache.jsonl"))

        _ = try fixture.scan()
        let manager = FileManager.default
        let fileMode = (try manager.attributesOfItem(atPath: fixture.cache.path)[.posixPermissions] as? NSNumber)?.intValue
        let directoryMode = (try manager.attributesOfItem(atPath: fixture.cache.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(fileMode == 0o600)
        #expect(directoryMode == 0o700)
    }

    @Test func scanNeverDeletesAnUnexpectedDirectoryAtTheCachePath() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        try manager.createDirectory(at: fixture.cache, withIntermediateDirectories: true)
        let sentinel = fixture.cache.appendingPathComponent("keep-me.txt")
        try Data("sentinel".utf8).write(to: sentinel)

        _ = try fixture.scan()

        var isDirectory: ObjCBool = false
        #expect(manager.fileExists(atPath: fixture.cache.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(manager.fileExists(atPath: sentinel.path))
    }

    @Test func scanDeduplicatesArchivedSessionsForkPrefixesAndClaudeFiles() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }

        let parentLines = [
            sessionMetadata(id: "parent"),
            codexEvent(timestamp: "2026-07-17T01:00:00.000Z", cumulative: 100, last: 100),
            codexEvent(timestamp: "2026-07-17T01:01:00.000Z", cumulative: 200, last: 100)
        ]
        try writeLines(parentLines, to: fixture.codexSessions.appendingPathComponent("parent.jsonl"))
        try writeLines(parentLines, to: fixture.codexArchive.appendingPathComponent("parent-copy.jsonl"))
        try writeLines([
            sessionMetadata(id: "fork", forkedFrom: "parent"),
            codexEvent(timestamp: "2026-07-17T01:00:00.000Z", cumulative: 100, last: 100),
            codexEvent(timestamp: "2026-07-17T01:01:00.000Z", cumulative: 200, last: 100),
            codexEvent(timestamp: "2026-07-17T01:02:00.000Z", cumulative: 250, last: 50)
        ], to: fixture.codexSessions.appendingPathComponent("fork.jsonl"))

        let claude = claudeEvent(id: "shared-message", input: 10, cacheCreation: 20, cacheRead: 30, output: 40)
        try writeLines([claude], to: fixture.claudeProjects.appendingPathComponent("one.jsonl"))
        try writeLines([claude], to: fixture.claudeProjects.appendingPathComponent("two.jsonl"))

        let snapshot = try fixture.scan()
        #expect(snapshot.providers.first { $0.id == "codex" }?.totalTokens == 250)
        #expect(snapshot.providers.first { $0.id == "claude" }?.totalTokens == 100)
        #expect(snapshot.totalTokens == 350)
    }

    @Test func scanSkipsImportedCodexCopiesAndUsesTheOriginalClaudeSource() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }

        try writeLines([
            sessionMetadata(id: "imported-thread"),
            codexEvent(timestamp: "2026-07-17T01:00:00.000Z", cumulative: 5, last: 5)
        ], to: fixture.codexSessions.appendingPathComponent("imported-copy.jsonl"))

        let original = fixture.root.appendingPathComponent("external/original-claude.jsonl")
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeLines([
            claudeEvent(id: "original-message", input: 10, cacheCreation: 20, cacheRead: 30, output: 40)
        ], to: original)
        let registry: [String: Any] = [
            "records": [[
                "source_path": original.path,
                "imported_thread_id": "imported-thread"
            ]]
        ]
        let registryData = try JSONSerialization.data(withJSONObject: registry)
        try registryData.write(to: fixture.codexSessions.deletingLastPathComponent().appendingPathComponent("external_agent_session_imports.json"))

        let snapshot = try fixture.scan()
        #expect(snapshot.providers.first { $0.id == "codex" }?.totalTokens == 0)
        #expect(snapshot.providers.first { $0.id == "claude" }?.totalTokens == 100)
        #expect(snapshot.totalTokens == 100)
    }

    @Test func scanKeepsLargeClaudeAssistantLinesWhenTopLevelTypeComesLate() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let largeLine = json([
            "timestamp": "2026-07-17T03:00:00.000Z",
            "type": "assistant",
            "message": [
                "id": "large-message",
                "role": "assistant",
                "content": [["type": "text", "text": String(repeating: "x", count: 100_000)]],
                "usage": [
                    "input_tokens": 10,
                    "cache_creation_input_tokens": 20,
                    "cache_read_input_tokens": 30,
                    "output_tokens": 40
                ]
            ]
        ])
        try writeLines([largeLine], to: fixture.claudeProjects.appendingPathComponent("large.jsonl"))

        let snapshot = try fixture.scan()
        #expect(snapshot.providers.first { $0.id == "claude" }?.totalTokens == 100)
        #expect(snapshot.unreadableFileCount == 0)
    }

    @Test func scanReportsTodayTokensForEachProviderAndTheCombinedTotal() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }
        let today = Calendar.autoupdatingCurrent.startOfDay(for: fixture.now)
        let yesterday = Calendar.autoupdatingCurrent.date(byAdding: .day, value: -1, to: today)!

        try writeLines([
            sessionMetadata(id: "today-root"),
            codexEvent(timestamp: isoString(yesterday), cumulative: 40, last: 40),
            codexEvent(timestamp: isoString(today), cumulative: 100, last: 60)
        ], to: fixture.codexSessions.appendingPathComponent("today.jsonl"))
        try writeLines([
            claudeEvent(
                id: "today-claude",
                timestamp: isoString(today),
                input: 10,
                cacheCreation: 20,
                cacheRead: 30,
                output: 40
            )
        ], to: fixture.claudeProjects.appendingPathComponent("today.jsonl"))

        let snapshot = try fixture.scan()
        #expect(snapshot.providers.first { $0.id == "codex" }?.todayTokens == 60)
        #expect(snapshot.providers.first { $0.id == "claude" }?.todayTokens == 100)
        #expect(snapshot.todayTokens == 160)
        #expect(snapshot.totalTokens == 200)
    }

    @Test func scanKeepsCumulativeDeltasAccurateForRecentQuotaWindows() throws {
        let fixture = try HistoryFixture()
        defer { fixture.remove() }

        try writeLines([
            sessionMetadata(id: "window-root"),
            codexEvent(timestamp: "2026-07-17T01:00:00.000Z", cumulative: 100, last: 100),
            codexEvent(timestamp: "2026-07-17T10:00:00.000Z", cumulative: 140, last: 40),
            codexEvent(timestamp: "2026-07-17T13:00:00.000Z", cumulative: 200, last: 60)
        ], to: fixture.codexSessions.appendingPathComponent("window.jsonl"))

        let recent = try fixture.scan().recentUsage.filter { $0.providerId == "codex" }
        #expect(recent.map(\.tokens) == [100, 40])
    }

    @Test func tokenEstimatePrefersTheFiveHourSessionOverWeeklyQuota() {
        let now = instant("2026-07-17T12:00:00Z")
        let provider = quotaProvider(
            id: "codex",
            fetchedAt: now,
            lines: [
                quotaLine(
                    label: "Session",
                    used: 25,
                    resetsAt: instant("2026-07-17T15:00:00Z"),
                    durationMilliseconds: 5 * 60 * 60 * 1_000.0
                ),
                quotaLine(
                    label: "Weekly",
                    used: 50,
                    resetsAt: instant("2026-07-20T12:00:00Z"),
                    durationMilliseconds: 7 * 24 * 60 * 60 * 1_000.0
                )
            ]
        )
        let usage = [
            timedUsage(providerId: "codex", at: "2026-07-17T09:59:59Z", tokens: 900),
            timedUsage(providerId: "codex", at: "2026-07-17T10:00:00Z", tokens: 100)
        ]

        let estimate = TokenCapacityEstimator.estimate(
            providerId: "codex",
            quotaProvider: provider,
            recentUsage: usage,
            historyGeneratedAt: now,
            historyFirstActivityDate: nil
        )

        #expect(estimate?.window == .fiveHour)
        #expect(estimate?.observedTokens == 100)
        #expect(estimate?.remainingTokens == 300)
    }

    @Test func tokenEstimateFallsBackToWeeklyWhenThereIsNoSessionQuota() {
        let now = instant("2026-07-17T12:00:00Z")
        let provider = quotaProvider(
            id: "claude",
            fetchedAt: now,
            lines: [
                quotaLine(
                    label: "Weekly",
                    used: 40,
                    resetsAt: instant("2026-07-20T12:00:00Z"),
                    durationMilliseconds: 7 * 24 * 60 * 60 * 1_000.0
                )
            ]
        )

        let estimate = TokenCapacityEstimator.estimate(
            providerId: "claude",
            quotaProvider: provider,
            recentUsage: [timedUsage(providerId: "claude", at: "2026-07-15T12:00:00Z", tokens: 200)],
            historyGeneratedAt: now,
            historyFirstActivityDate: nil
        )

        #expect(estimate?.window == .weekly)
        #expect(estimate?.observedTokens == 200)
        #expect(estimate?.remainingTokens == 300)
    }

    @Test func tokenEstimateFallsBackToWeeklyWhenTheSessionWindowIsExpired() {
        let now = instant("2026-07-17T12:00:00Z")
        let provider = quotaProvider(
            id: "codex",
            fetchedAt: now,
            lines: [
                quotaLine(
                    label: "Session",
                    used: 25,
                    resetsAt: instant("2026-07-17T11:59:59Z"),
                    durationMilliseconds: 5 * 60 * 60 * 1_000.0
                ),
                quotaLine(
                    label: "Weekly",
                    used: 50,
                    resetsAt: instant("2026-07-20T12:00:00Z"),
                    durationMilliseconds: 7 * 24 * 60 * 60 * 1_000.0
                )
            ]
        )

        let estimate = TokenCapacityEstimator.estimate(
            providerId: "codex",
            quotaProvider: provider,
            recentUsage: [timedUsage(providerId: "codex", at: "2026-07-15T12:00:00Z", tokens: 100)],
            historyGeneratedAt: now,
            historyFirstActivityDate: nil
        )

        #expect(estimate?.window == .weekly)
        #expect(estimate?.remainingTokens == 100)
    }

    @Test func tokenEstimateSkipsAReclassifiedSessionAndUsesTheRealWeeklyLine() {
        let now = instant("2026-07-17T12:00:00Z")
        let provider = quotaProvider(
            id: "codex",
            fetchedAt: now,
            lines: [
                quotaLine(
                    label: "Session",
                    used: 12,
                    resetsAt: instant("2026-07-24T12:00:00Z"),
                    durationMilliseconds: 5 * 60 * 60 * 1_000.0
                ),
                quotaLine(
                    label: "Spark",
                    used: 20,
                    resetsAt: instant("2026-07-20T12:00:00Z"),
                    durationMilliseconds: 7 * 24 * 60 * 60 * 1_000.0
                )
            ]
        )

        let estimate = TokenCapacityEstimator.estimate(
            providerId: "codex",
            quotaProvider: provider,
            recentUsage: [timedUsage(providerId: "codex", at: "2026-07-15T12:00:00Z", tokens: 100)],
            historyGeneratedAt: now,
            historyFirstActivityDate: nil
        )

        #expect(estimate?.window == .weekly)
        #expect(estimate?.remainingTokens == 400)
    }

    @Test func tokenEstimateRejectsQuotaAndHistorySnapshotsThatAreTooFarApart() {
        let now = instant("2026-07-17T12:00:00Z")
        let provider = quotaProvider(
            id: "codex",
            fetchedAt: now,
            lines: [quotaLine(
                label: "Session",
                used: 50,
                resetsAt: instant("2026-07-17T15:00:00Z"),
                durationMilliseconds: 5 * 60 * 60 * 1_000.0
            )]
        )

        let estimate = TokenCapacityEstimator.estimate(
            providerId: "codex",
            quotaProvider: provider,
            recentUsage: [timedUsage(providerId: "codex", at: "2026-07-17T11:00:00Z", tokens: 100)],
            historyGeneratedAt: now.addingTimeInterval(-121),
            historyFirstActivityDate: nil
        )

        #expect(estimate == nil)
    }

    @Test func tokenEstimateIncludesWindowBoundariesAcrossMidnight() {
        let now = instant("2026-07-17T01:00:00Z")
        let provider = quotaProvider(
            id: "codex",
            fetchedAt: now,
            lines: [
                quotaLine(
                    label: "Session",
                    used: 50,
                    resetsAt: instant("2026-07-17T04:00:00Z"),
                    durationMilliseconds: 5 * 60 * 60 * 1_000.0
                )
            ]
        )
        let usage = [
            timedUsage(providerId: "codex", at: "2026-07-16T22:59:59Z", tokens: 1_000),
            timedUsage(providerId: "codex", at: "2026-07-16T23:00:00Z", tokens: 100),
            timedUsage(providerId: "codex", at: "2026-07-17T00:30:00Z", tokens: 100),
            timedUsage(providerId: "codex", at: "2026-07-17T01:00:00Z", tokens: 100),
            timedUsage(providerId: "codex", at: "2026-07-17T01:00:01Z", tokens: 1_000)
        ]

        let estimate = TokenCapacityEstimator.estimate(
            providerId: "codex",
            quotaProvider: provider,
            recentUsage: usage,
            historyGeneratedAt: now,
            historyFirstActivityDate: nil
        )

        #expect(estimate?.windowStart == instant("2026-07-16T23:00:00Z"))
        #expect(estimate?.observedTokens == 300)
        #expect(estimate?.remainingTokens == 300)
    }

    @Test func tokenEstimateRequiresAtLeastOnePercentOfObservedQuotaUse() {
        let now = instant("2026-07-17T12:00:00Z")
        let usage = [timedUsage(providerId: "codex", at: "2026-07-17T11:00:00Z", tokens: 100)]
        let zeroProvider = quotaProvider(
            id: "codex",
            fetchedAt: now,
            lines: [quotaLine(
                label: "Session",
                used: 0,
                resetsAt: instant("2026-07-17T15:00:00Z"),
                durationMilliseconds: 5 * 60 * 60 * 1_000.0
            )]
        )
        let belowOnePercentProvider = quotaProvider(
            id: "codex",
            fetchedAt: now,
            lines: [quotaLine(
                label: "Session",
                used: 0.99,
                resetsAt: instant("2026-07-17T15:00:00Z"),
                durationMilliseconds: 5 * 60 * 60 * 1_000.0
            )]
        )

        #expect(TokenCapacityEstimator.estimate(
            providerId: "codex",
            quotaProvider: zeroProvider,
            recentUsage: usage,
            historyGeneratedAt: now,
            historyFirstActivityDate: nil
        ) == nil)
        #expect(TokenCapacityEstimator.estimate(
            providerId: "codex",
            quotaProvider: belowOnePercentProvider,
            recentUsage: usage,
            historyGeneratedAt: now,
            historyFirstActivityDate: nil
        ) == nil)
    }

    @Test func tokenEstimateReturnsZeroAtOneHundredPercentUsed() {
        let now = instant("2026-07-17T12:00:00Z")
        let provider = quotaProvider(
            id: "codex",
            fetchedAt: now,
            lines: [quotaLine(
                label: "Session",
                used: 100,
                resetsAt: instant("2026-07-17T15:00:00Z"),
                durationMilliseconds: 5 * 60 * 60 * 1_000.0
            )]
        )

        let estimate = TokenCapacityEstimator.estimate(
            providerId: "codex",
            quotaProvider: provider,
            recentUsage: [timedUsage(providerId: "codex", at: "2026-07-17T11:00:00Z", tokens: 500)],
            historyGeneratedAt: now,
            historyFirstActivityDate: nil
        )

        #expect(estimate?.observedTokens == 500)
        #expect(estimate?.remainingTokens == 0)
    }

    @Test func tokenEstimateKeepsProviderHistoriesIsolated() {
        let now = instant("2026-07-17T12:00:00Z")
        let provider = quotaProvider(
            id: "codex",
            fetchedAt: now,
            lines: [quotaLine(
                label: "Session",
                used: 50,
                resetsAt: instant("2026-07-17T15:00:00Z"),
                durationMilliseconds: 5 * 60 * 60 * 1_000.0
            )]
        )
        let usage = [
            timedUsage(providerId: "Codex", at: "2026-07-17T11:00:00Z", tokens: 100),
            timedUsage(providerId: "claude", at: "2026-07-17T11:00:00Z", tokens: 10_000)
        ]

        let estimate = TokenCapacityEstimator.estimate(
            providerId: "codex",
            quotaProvider: provider,
            recentUsage: usage,
            historyGeneratedAt: now,
            historyFirstActivityDate: nil
        )

        #expect(estimate?.observedTokens == 100)
        #expect(estimate?.remainingTokens == 100)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func sessionMetadata(
        id: String,
        parent: String? = nil,
        agentPath: String? = nil,
        forkedFrom: String? = nil
    ) -> Data {
        var payload: [String: Any] = ["id": id]
        if let parent { payload["parent_thread_id"] = parent }
        if let agentPath { payload["agent_path"] = agentPath }
        if let forkedFrom { payload["forked_from_id"] = forkedFrom }
        return json(["timestamp": "2026-07-17T00:00:00.000Z", "type": "session_meta", "payload": payload])
    }

    private func codexEvent(timestamp: String, cumulative: Int64, last: Int64) -> Data {
        json([
            "timestamp": timestamp,
            "type": "event_msg",
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": ["total_tokens": cumulative],
                    "last_token_usage": ["total_tokens": last]
                ]
            ]
        ])
    }

    private func claudeEvent(
        id: String,
        timestamp: String = "2026-07-17T03:00:00.000Z",
        input: Int64,
        cacheCreation: Int64,
        cacheRead: Int64,
        output: Int64
    ) -> Data {
        json([
            "timestamp": timestamp,
            "type": "assistant",
            "requestId": "request-\(id)",
            "message": [
                "id": id,
                "usage": [
                    "input_tokens": input,
                    "cache_creation_input_tokens": cacheCreation,
                    "cache_read_input_tokens": cacheRead,
                    "output_tokens": output,
                    "iterations": [["input_tokens": 9_999]]
                ]
            ]
        ])
    }

    private func kimiEvent(
        timestamp: String,
        input: Int64,
        cacheCreation: Int64,
        cacheRead: Int64,
        output: Int64
    ) -> Data {
        json([
            "type": "turn.step.completed",
            "time": instant(timestamp).timeIntervalSince1970 * 1_000,
            "turnId": 1,
            "step": 1,
            "usage": [
                "inputOther": input,
                "inputCacheCreation": cacheCreation,
                "inputCacheRead": cacheRead,
                "output": output
            ]
        ])
    }

    private func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func data(_ value: String) -> Data { Data(value.utf8) }

    private func instant(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func timedUsage(providerId: String, at timestamp: String, tokens: Int64) -> TimedProviderTokenUsage {
        TimedProviderTokenUsage(providerId: providerId, timestamp: instant(timestamp), tokens: tokens)
    }

    private func quotaProvider(id: String, fetchedAt: Date, lines: [UsageLine]) -> ProviderUsage {
        ProviderUsage(
            providerId: id,
            displayName: id.capitalized,
            plan: nil,
            lines: lines,
            fetchedAt: fetchedAt
        )
    }

    private func quotaLine(
        label: String,
        used: Double,
        resetsAt: Date,
        durationMilliseconds: Double
    ) -> UsageLine {
        UsageLine(
            type: "progress",
            label: label,
            used: used,
            limit: 100,
            resetsAt: resetsAt,
            periodDurationMs: durationMilliseconds,
            value: nil,
            subtitle: nil
        )
    }

    private func writeLines(_ lines: [Data], to url: URL) throws {
        let payload = lines.reduce(into: Data()) { result, line in
            result.append(line)
            result.append(0x0A)
        }
        try payload.write(to: url)
    }

    private func appendLines(_ lines: [Data], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for line in lines {
            try handle.write(contentsOf: line)
            try handle.write(contentsOf: Data([0x0A]))
        }
    }
}

private struct HistoryFixture {
    let root: URL
    let codexSessions: URL
    let codexArchive: URL
    let claudeProjects: URL
    let cache: URL
    let now: Date

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        codexSessions = root.appendingPathComponent(".codex/sessions", isDirectory: true)
        codexArchive = root.appendingPathComponent(".codex/archived_sessions", isDirectory: true)
        claudeProjects = root.appendingPathComponent(".claude/projects", isDirectory: true)
        cache = root.appendingPathComponent("cache/token-history.json")
        now = ISO8601DateFormatter().date(from: "2026-07-17T12:00:00Z")!
        try FileManager.default.createDirectory(at: codexSessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexArchive, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeProjects, withIntermediateDirectories: true)
    }

    func scan() throws -> TokenHistorySnapshot {
        try TokenHistoryScanner.scan(
            now: now,
            homeDirectory: root,
            cacheURL: cache,
            environment: [:]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
