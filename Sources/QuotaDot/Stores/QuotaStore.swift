import Foundation
import Observation
import OSLog

@MainActor @Observable
final class QuotaStore {
    private(set) var providers: [ProviderUsage] = []
    private(set) var lastUpdated: Date?
    private(set) var errorMessageKey: String?
    private(set) var isRefreshing = false
    private(set) var activeProviderIds: Set<String> = []
    private(set) var weather: WeatherSnapshot?
    private(set) var locationStatusKey: String?
    private(set) var codexResetCredits: CodexResetCredits?

    private let client = OpenUsageClient()
    private let weatherClient = WeatherClient()
    private let locationClient = LocationClient()
    private let codexDirectClient = CodexDirectClient()
    private let claudeDirectClient = ClaudeDirectClient()
    private let logger = Logger(subsystem: "com.cmsjcm.QuotaDot", category: "quota")
    private var activityTask: Task<Void, Never>?
    private var weatherTask: Task<Void, Never>?
    private var openUsageTask: Task<Void, Never>?
    private var codexTask: Task<Void, Never>?
    private var claudeTask: Task<Void, Never>?
    private var directCodexAvailable = false
    private var directClaudeAvailable = false

    var isConsuming: Bool { !activeProviderIds.isEmpty }
    func isConsuming(_ provider: ProviderUsage) -> Bool {
        activeProviderIds.contains(provider.id)
    }

    var lowestRemaining: Double? {
        providers.flatMap { [$0.session?.remainingPercent, $0.weekly?.remainingPercent] }.compactMap { $0 }.min()
    }

    var health: QuotaHealth { QuotaHealth(remaining: lowestRemaining) }

    func start() async {
        activityTask = Task { await monitorLocalActivity() }
        weatherTask = Task { await monitorWeather() }
        defer {
            activityTask?.cancel()
            weatherTask?.cancel()
            openUsageTask?.cancel()
            codexTask?.cancel()
            claudeTask?.cancel()
        }
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
            await refresh()
        }
    }

    private func monitorWeather() async {
        while !Task.isCancelled {
            do {
                let location = try await locationClient.currentLocation()
                let locationName = await locationClient.displayName(for: location, language: .simplifiedChinese)
                let englishLocationName = await locationClient.displayName(for: location, language: .english)
                logger.info(
                    "Weather location resolved, accuracy \(Int(location.horizontalAccuracy), privacy: .public)m, age \(Int(abs(location.timestamp.timeIntervalSinceNow)), privacy: .public)s"
                )
                weather = try await weatherClient.fetch(
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude,
                    locationName: locationName,
                    englishLocationName: englishLocationName
                )
                locationStatusKey = nil
            } catch LocationClient.LocationError.permissionDenied {
                weather = nil
                locationStatusKey = "location.permissionDenied"
            } catch LocationClient.LocationError.servicesDisabled {
                weather = nil
                locationStatusKey = "location.servicesDisabled"
            } catch {
                locationStatusKey = "location.weatherFailed"
            }
            try? await Task.sleep(for: .seconds(600))
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        launchOpenUsageRefresh()
        launchCodexRefresh()
        launchClaudeRefresh()
    }

    private func launchOpenUsageRefresh() {
        guard openUsageTask == nil else { return }
        let client = client
        openUsageTask = Task { [weak self] in
            let result = try? await client.fetch()
            guard let self, !Task.isCancelled else { return }
            self.applyOpenUsage(result)
            self.openUsageTask = nil
        }
    }

    private func launchCodexRefresh() {
        guard codexTask == nil else { return }
        let client = codexDirectClient
        codexTask = Task { [weak self] in
            let result = try? await client.fetch()
            guard let self, !Task.isCancelled else { return }
            self.applyDirectCodex(result)
            self.codexTask = nil
        }
    }

    private func launchClaudeRefresh() {
        guard claudeTask == nil else { return }
        let client = claudeDirectClient
        claudeTask = Task { [weak self] in
            let result = try? await client.fetch()
            guard let self, !Task.isCancelled else { return }
            self.applyDirectClaude(result)
            self.claudeTask = nil
        }
    }

    private func applyOpenUsage(_ result: [ProviderUsage]?) {
        guard let result else {
            logger.info("OpenUsage refresh failed")
            setFailureMessageIfNeeded()
            return
        }

        var fresh = providers
        for provider in result {
            let providerId = provider.providerId.lowercased()
            if providerId == "codex", directCodexAvailable { continue }
            if providerId == "claude", directClaudeAvailable { continue }
            replace(provider, in: &fresh)
        }
        commit(fresh)
        logger.info("OpenUsage refresh succeeded")
    }

    private func applyDirectCodex(_ result: CodexDirectSnapshot?) {
        guard let result else {
            logger.info("Codex direct refresh failed")
            setFailureMessageIfNeeded()
            return
        }

        directCodexAvailable = true
        var fresh = providers
        replace(result.provider, in: &fresh)
        if let resetCredits = result.resetCredits { codexResetCredits = resetCredits }
        commit(fresh)
        logger.info("Codex direct refresh succeeded")
    }

    private func applyDirectClaude(_ result: ProviderUsage?) {
        guard let result else {
            logger.info("Claude direct refresh failed")
            setFailureMessageIfNeeded()
            return
        }

        directClaudeAvailable = true
        var fresh = providers
        replace(result, in: &fresh)
        commit(fresh)
        logger.info("Claude direct refresh succeeded")
    }

    private func replace(_ provider: ProviderUsage, in providers: inout [ProviderUsage]) {
        providers.removeAll { $0.providerId.caseInsensitiveCompare(provider.providerId) == .orderedSame }
        providers.append(provider)
    }

    private func commit(_ fresh: [ProviderUsage]) {
        let sorted = fresh.sorted {
            if $0.providerId.lowercased() == "codex" { return true }
            if $1.providerId.lowercased() == "codex" { return false }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        providers = sorted
        lastUpdated = .now
        errorMessageKey = nil
    }

    private func setFailureMessageIfNeeded() {
        guard providers.isEmpty else { return }
        errorMessageKey = "error.quotaUnavailable"
    }

    private func monitorLocalActivity() async {
        while !Task.isCancelled {
            let detected = detectLocalActivity()
            if detected != activeProviderIds {
                logger.info("Local activity changed: \(detected.sorted().joined(separator: ","), privacy: .public)")
            }
            activeProviderIds = detected
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func detectLocalActivity(now: Date = .now) -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var active: Set<String> = []

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy/MM/dd"
        let codexDirectory = home
            .appendingPathComponent(".codex/sessions", isDirectory: true)
            .appendingPathComponent(dayFormatter.string(from: now), isDirectory: true)
        if hasRecentlyModifiedJSONL(in: codexDirectory, now: now) { active.insert("codex") }

        let claudeDirectory = home.appendingPathComponent(".claude/projects", isDirectory: true)
        if hasRecentlyModifiedJSONL(in: claudeDirectory, now: now) { active.insert("claude") }
        return active
    }

    private func hasRecentlyModifiedJSONL(in directory: URL, now: Date) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            if ActivityDetectionPolicy.isActive(modifiedAt: modified, now: now) { return true }
        }
        return false
    }

}

enum ActivityDetectionPolicy {
    static let recentWriteWindow: TimeInterval = 4

    static func isActive(modifiedAt: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(modifiedAt)
        return age >= -1 && age <= recentWriteWindow
    }
}
