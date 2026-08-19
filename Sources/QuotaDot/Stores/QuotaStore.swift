import Foundation
import Observation
import OSLog

enum DeepSeekErrorKind: Error, Sendable, Equatable {
    case keyMissing
    case invalidLocalKey
    case credentialStoreFailure
    case unauthorized
    case clientRejected
    case rateLimited
    case serverUnavailable
    case unexpectedHTTPStatus
    case networkFailure
    case redirectRejected
    case responseTooLarge
    case malformedResponse
    case cnyBalanceMissing
}

enum DeepSeekRefreshStatus: Sendable, Equatable {
    case idle
    case checking
    case live(fetchedAt: Date)
    case cached(
        lastSuccessfulFetchAt: Date,
        currentError: DeepSeekErrorKind,
        contractFailure: DeepSeekErrorKind?,
        contractCacheExpiresAt: Date?
    )
    case failed(DeepSeekErrorKind)
}

enum GLMErrorKind: Error, Sendable, Equatable {
    case keyMissing
    case invalidLocalKey
    case credentialStoreFailure
    case unauthorized
    case clientRejected
    case rateLimited
    case serverUnavailable
    case unexpectedHTTPStatus
    case networkFailure
    case redirectRejected
    case responseTooLarge
    case malformedResponse
    case quotaMissing
}

enum GLMRefreshStatus: Sendable, Equatable {
    case idle
    case checking
    case live(fetchedAt: Date)
    case failed(GLMErrorKind)
}

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
    private(set) var deepSeekStatus: DeepSeekRefreshStatus = .idle
    private(set) var glmStatus: GLMRefreshStatus = .idle

    let deepSeekCredentials: DeepSeekCredentialManager
    let glmCredentials: GLMCredentialManager
    private let client: OpenUsageClient
    private let weatherClient: WeatherClient
    private let locationClient: LocationClient
    private let codexDirectClient: CodexDirectClient
    private let claudeDirectClient: ClaudeDirectClient
    private let kimiDirectClient = KimiDirectClient()
    private let deepSeekClient: any DeepSeekUsageClient
    private let glmClient: any GLMUsageClient
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.cmsjcm.QuotaDot", category: "quota")
    private var activityTask: Task<Void, Never>?
    private var weatherTask: Task<Void, Never>?
    private var openUsageTask: Task<Void, Never>?
    private var codexTask: Task<Void, Never>?
    private var claudeTask: Task<Void, Never>?
    private var kimiTask: Task<Void, Never>?
    private var deepSeekTask: Task<Void, Never>?
    private var deepSeekTaskID: UUID?
    private var pendingDeepSeekAPIKey: String?
    private var suppressStoredDeepSeekCredential = false
    private var deepSeekGeneration: UInt64 = 0
    private var glmTask: Task<Void, Never>?
    private var glmTaskID: UUID?
    private var pendingGLMAPIKey: String?
    private var suppressStoredGLMCredential = false
    private var glmGeneration: UInt64 = 0
    private var activeRefreshCount = 0
    private var directCodexAvailable = false
    private var directClaudeAvailable = false
    private var directKimiAvailable = false

    init(
        deepSeekCredentials: DeepSeekCredentialManager = DeepSeekCredentialManager(),
        deepSeekClient: any DeepSeekUsageClient = DeepSeekDirectClient(),
        glmCredentials: GLMCredentialManager = GLMCredentialManager(),
        glmClient: any GLMUsageClient = GLMDirectClient(),
        client: OpenUsageClient = OpenUsageClient(),
        weatherClient: WeatherClient = WeatherClient(),
        locationClient: LocationClient = LocationClient(),
        codexDirectClient: CodexDirectClient = CodexDirectClient(),
        claudeDirectClient: ClaudeDirectClient = ClaudeDirectClient(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.deepSeekCredentials = deepSeekCredentials
        self.deepSeekClient = deepSeekClient
        self.glmCredentials = glmCredentials
        self.glmClient = glmClient
        self.client = client
        self.weatherClient = weatherClient
        self.locationClient = locationClient
        self.codexDirectClient = codexDirectClient
        self.claudeDirectClient = claudeDirectClient
        self.now = now
    }

    var isConsuming: Bool { !activeProviderIds.isEmpty }
    func isConsuming(_ provider: ProviderUsage) -> Bool {
        activeProviderIds.contains(provider.id)
    }

    var lowestRemaining: Double? {
        providers.flatMap { [$0.session?.remainingPercent, $0.weekly?.remainingPercent] }.compactMap { $0 }.min()
    }
    var displayRemaining: Double? { providers.compactMap(\.displayRemainingPercent).min() }

    var health: QuotaHealth { QuotaHealth(remaining: lowestRemaining) }
    var hasQuotaProviders: Bool { providers.contains { $0.balance == nil } }
    var deepSeekProvider: ProviderUsage? { providers.first { $0.providerId.lowercased() == "deepseek" } }
    var hasPendingDeepSeekCredential: Bool { pendingDeepSeekAPIKey != nil }
    var glmProvider: ProviderUsage? { providers.first { $0.providerId.lowercased() == "glm" } }
    var hasPendingGLMCredential: Bool { pendingGLMAPIKey != nil }

    func start() async {
        activityTask = Task { await monitorLocalActivity() }
        weatherTask = Task { await monitorWeather() }
        defer {
            activityTask?.cancel()
            weatherTask?.cancel()
            openUsageTask?.cancel()
            codexTask?.cancel()
            claudeTask?.cancel()
            kimiTask?.cancel()
            deepSeekTask?.cancel()
            glmTask?.cancel()
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
        launchOpenUsageRefresh()
        launchCodexRefresh()
        launchClaudeRefresh()
        launchKimiRefresh()
        launchDeepSeekRefresh()
        launchGLMRefresh()
    }

    func refreshGLM() {
        errorMessageKey = nil
        launchGLMRefresh()
    }

    /// Validates the pasted key against GLM first. The key is persisted to
    /// Keychain only after the official quota request succeeds.
    @discardableResult
    func connectGLM(apiKey candidate: String) -> Bool {
        guard let apiKey = try? GLMDirectClient.validatedAPIKey(candidate) else { return false }
        resetGLMConnection(status: .checking)
        pendingGLMAPIKey = apiKey
        suppressStoredGLMCredential = false
        launchGLMRefresh(apiKey: apiKey, saveAfterSuccess: true)
        return true
    }

    @discardableResult
    func disconnectGLM() -> Bool {
        pendingGLMAPIKey = nil
        resetGLMConnection(status: .idle)
        do {
            try glmCredentials.deleteAPIKey()
            suppressStoredGLMCredential = false
            return true
        } catch {
            // Never reload a credential that the user asked us to remove.
            suppressStoredGLMCredential = true
            glmStatus = .failed(.credentialStoreFailure)
            return false
        }
    }

    private func resetGLMConnection(status: GLMRefreshStatus) {
        glmGeneration &+= 1
        glmTask?.cancel()
        glmTask = nil
        glmTaskID = nil
        removeGLMProvider()
        errorMessageKey = nil
        glmStatus = status
    }

    func refreshDeepSeek() {
        errorMessageKey = nil
        launchDeepSeekRefresh()
    }

    /// Validates the pasted key against DeepSeek first. The key is persisted to
    /// Keychain only after the official balance request succeeds.
    @discardableResult
    func connectDeepSeek(apiKey candidate: String) -> Bool {
        guard let apiKey = try? DeepSeekDirectClient.validatedAPIKey(candidate) else { return false }
        resetDeepSeekConnection(status: .checking)
        pendingDeepSeekAPIKey = apiKey
        suppressStoredDeepSeekCredential = false
        launchDeepSeekRefresh(apiKey: apiKey, saveAfterSuccess: true)
        return true
    }

    @discardableResult
    func disconnectDeepSeek() -> Bool {
        pendingDeepSeekAPIKey = nil
        resetDeepSeekConnection(status: .idle)
        do {
            try deepSeekCredentials.deleteAPIKey()
            suppressStoredDeepSeekCredential = false
            return true
        } catch {
            // Never reload a credential that the user asked us to remove.
            suppressStoredDeepSeekCredential = true
            deepSeekStatus = .failed(.credentialStoreFailure)
            return false
        }
    }

    private func resetDeepSeekConnection(status: DeepSeekRefreshStatus) {
        deepSeekGeneration &+= 1
        deepSeekTask?.cancel()
        deepSeekTask = nil
        deepSeekTaskID = nil
        removeDeepSeekProvider()
        errorMessageKey = nil
        deepSeekStatus = status
    }

    private func refreshStarted() {
        activeRefreshCount += 1
        isRefreshing = true
    }

    private func refreshFinished() {
        activeRefreshCount = max(activeRefreshCount - 1, 0)
        isRefreshing = activeRefreshCount > 0
    }

    private func launchOpenUsageRefresh() {
        guard openUsageTask == nil else { return }
        let client = client
        refreshStarted()
        openUsageTask = Task { [weak self] in
            let result = try? await client.fetch()
            guard let self else { return }
            if !Task.isCancelled { self.applyOpenUsage(result) }
            self.openUsageTask = nil
            self.refreshFinished()
        }
    }

    private func launchCodexRefresh() {
        guard codexTask == nil else { return }
        let client = codexDirectClient
        refreshStarted()
        codexTask = Task { [weak self] in
            let result = try? await client.fetch()
            guard let self else { return }
            if !Task.isCancelled { self.applyDirectCodex(result) }
            self.codexTask = nil
            self.refreshFinished()
        }
    }

    private func launchClaudeRefresh() {
        guard claudeTask == nil else { return }
        let client = claudeDirectClient
        refreshStarted()
        claudeTask = Task { [weak self] in
            let result = try? await client.fetch()
            guard let self else { return }
            if !Task.isCancelled { self.applyDirectClaude(result) }
            self.claudeTask = nil
            self.refreshFinished()
        }
    }

    private func launchKimiRefresh() {
        guard kimiTask == nil else { return }
        let client = kimiDirectClient
        refreshStarted()
        kimiTask = Task { [weak self] in
            let result = try? await client.fetch()
            guard let self else { return }
            if !Task.isCancelled { self.applyDirectKimi(result) }
            self.kimiTask = nil
            self.refreshFinished()
        }
    }

    private func launchDeepSeekRefresh(apiKey suppliedAPIKey: String? = nil, saveAfterSuccess: Bool = false) {
        // Expiring stale contract data must not consume this refresh attempt.
        // Continue immediately with a fresh request after removing the cache.
        expireContractCacheIfNeeded()
        guard deepSeekTask == nil else { return }
        let apiKey: String
        let shouldSaveAfterSuccess: Bool
        if let suppliedAPIKey {
            apiKey = suppliedAPIKey
            shouldSaveAfterSuccess = saveAfterSuccess
        } else if let pendingDeepSeekAPIKey {
            apiKey = pendingDeepSeekAPIKey
            shouldSaveAfterSuccess = true
        } else {
            guard !suppressStoredDeepSeekCredential else {
                deepSeekStatus = .failed(.credentialStoreFailure)
                return
            }
            do {
                guard let stored = try deepSeekCredentials.loadAPIKey() else {
                    applyDeepSeekFailure(.keyMissing)
                    return
                }
                apiKey = stored
                shouldSaveAfterSuccess = false
            } catch {
                applyDeepSeekFailure(.credentialStoreFailure)
                return
            }
        }
        let client = deepSeekClient
        let generation = deepSeekGeneration
        let taskID = UUID()
        deepSeekTaskID = taskID
        if deepSeekProvider == nil {
            errorMessageKey = nil
            deepSeekStatus = .checking
        }
        refreshStarted()
        deepSeekTask = Task { [weak self] in
            let result: Result<ProviderUsage, DeepSeekErrorKind>
            do {
                result = .success(try await client.fetch(apiKey: apiKey))
            } catch is CancellationError {
                result = .failure(.networkFailure)
            } catch let error as DeepSeekClientError {
                result = .failure(Self.mapDeepSeekError(error))
            } catch {
                result = .failure(.networkFailure)
            }
            guard let self else { return }
            let current = generation == self.deepSeekGeneration && taskID == self.deepSeekTaskID
            if current, !Task.isCancelled {
                switch result {
                case let .success(provider):
                    if shouldSaveAfterSuccess {
                        do {
                            try self.deepSeekCredentials.saveAPIKey(apiKey)
                            self.pendingDeepSeekAPIKey = nil
                            self.suppressStoredDeepSeekCredential = false
                            self.applyDeepSeek(provider)
                        } catch {
                            self.removeDeepSeekProvider()
                            self.deepSeekStatus = .failed(.credentialStoreFailure)
                        }
                    } else {
                        self.applyDeepSeek(provider)
                    }
                case let .failure(error):
                    self.applyDeepSeekFailure(error)
                }
            }
            if current {
                self.deepSeekTask = nil
                self.deepSeekTaskID = nil
            }
            self.refreshFinished()
        }
    }

    private func launchGLMRefresh(apiKey suppliedAPIKey: String? = nil, saveAfterSuccess: Bool = false) {
        guard glmTask == nil else { return }
        let apiKey: String
        let shouldSaveAfterSuccess: Bool
        if let suppliedAPIKey {
            apiKey = suppliedAPIKey
            shouldSaveAfterSuccess = saveAfterSuccess
        } else if let pendingGLMAPIKey {
            apiKey = pendingGLMAPIKey
            shouldSaveAfterSuccess = true
        } else {
            guard !suppressStoredGLMCredential else {
                glmStatus = .failed(.credentialStoreFailure)
                return
            }
            do {
                guard let stored = try glmCredentials.loadAPIKey() else {
                    applyGLMFailure(.keyMissing)
                    return
                }
                apiKey = stored
                shouldSaveAfterSuccess = false
            } catch {
                applyGLMFailure(.credentialStoreFailure)
                return
            }
        }
        let client = glmClient
        let generation = glmGeneration
        let taskID = UUID()
        glmTaskID = taskID
        if glmProvider == nil {
            errorMessageKey = nil
            glmStatus = .checking
        }
        refreshStarted()
        glmTask = Task { [weak self] in
            let result: Result<ProviderUsage, GLMErrorKind>
            do {
                result = .success(try await client.fetch(apiKey: apiKey))
            } catch is CancellationError {
                result = .failure(.networkFailure)
            } catch let error as GLMClientError {
                result = .failure(Self.mapGLMError(error))
            } catch {
                result = .failure(.networkFailure)
            }
            guard let self else { return }
            let current = generation == self.glmGeneration && taskID == self.glmTaskID
            if current, !Task.isCancelled {
                switch result {
                case let .success(provider):
                    if shouldSaveAfterSuccess {
                        do {
                            try self.glmCredentials.saveAPIKey(apiKey)
                            self.pendingGLMAPIKey = nil
                            self.suppressStoredGLMCredential = false
                            self.applyGLM(provider)
                        } catch {
                            self.removeGLMProvider()
                            self.glmStatus = .failed(.credentialStoreFailure)
                        }
                    } else {
                        self.applyGLM(provider)
                    }
                case let .failure(error):
                    self.applyGLMFailure(error)
                }
            }
            if current {
                self.glmTask = nil
                self.glmTaskID = nil
            }
            self.refreshFinished()
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
            if providerId == "kimi", directKimiAvailable { continue }
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

    private func applyDirectKimi(_ result: ProviderUsage?) {
        guard let result else {
            logger.info("Kimi direct refresh failed")
            setFailureMessageIfNeeded()
            return
        }

        directKimiAvailable = true
        var fresh = providers
        replace(result, in: &fresh)
        commit(fresh)
        logger.info("Kimi direct refresh succeeded")
    }

    private func applyDeepSeek(_ provider: ProviderUsage) {
        var fresh = providers
        replace(provider, in: &fresh)
        commit(fresh)
        deepSeekStatus = .live(fetchedAt: provider.fetchedAt ?? now())
        logger.info("DeepSeek direct refresh succeeded")
    }

    private func applyDeepSeekFailure(_ error: DeepSeekErrorKind) {
        logger.info("DeepSeek direct refresh failed: \(String(describing: error), privacy: .public)")
        switch error {
        case .unauthorized:
            removeDeepSeekProvider()
            pendingDeepSeekAPIKey = nil
            // Suppress the rejected credential before touching Keychain so a
            // deletion failure cannot cause periodic refreshes to resend it.
            suppressStoredDeepSeekCredential = true
            do {
                try deepSeekCredentials.deleteAPIKey()
                suppressStoredDeepSeekCredential = false
                deepSeekStatus = .failed(error)
            } catch {
                deepSeekStatus = .failed(.credentialStoreFailure)
            }
        case .keyMissing, .invalidLocalKey, .credentialStoreFailure, .clientRejected:
            removeDeepSeekProvider()
            deepSeekStatus = .failed(error)
        case .networkFailure, .rateLimited, .serverUnavailable:
            applyTransientDeepSeekFailure(error)
        case .unexpectedHTTPStatus, .redirectRejected, .responseTooLarge, .malformedResponse, .cnyBalanceMissing:
            applyContractDeepSeekFailure(error)
        }
        setFailureMessageIfNeeded()
    }

    private func applyTransientDeepSeekFailure(_ error: DeepSeekErrorKind) {
        guard let provider = deepSeekProvider, let fetchedAt = provider.fetchedAt else {
            deepSeekStatus = .failed(error)
            return
        }
        let contract: (DeepSeekErrorKind?, Date?) = switch deepSeekStatus {
        case let .cached(_, _, failure, expiry): (failure, expiry)
        default: (nil, nil)
        }
        if let failure = contract.0, let expiry = contract.1, now() >= expiry {
            removeDeepSeekProvider()
            deepSeekStatus = .failed(failure)
            return
        }
        deepSeekStatus = .cached(
            lastSuccessfulFetchAt: fetchedAt,
            currentError: error,
            contractFailure: contract.0,
            contractCacheExpiresAt: contract.1
        )
    }

    private func applyContractDeepSeekFailure(_ error: DeepSeekErrorKind) {
        guard let provider = deepSeekProvider, let fetchedAt = provider.fetchedAt else {
            deepSeekStatus = .failed(error)
            return
        }
        let expiry = fetchedAt.addingTimeInterval(24 * 60 * 60)
        guard now() < expiry else {
            removeDeepSeekProvider()
            deepSeekStatus = .failed(error)
            return
        }
        deepSeekStatus = .cached(
            lastSuccessfulFetchAt: fetchedAt,
            currentError: error,
            contractFailure: error,
            contractCacheExpiresAt: expiry
        )
    }

    @discardableResult
    private func expireContractCacheIfNeeded() -> Bool {
        guard case let .cached(_, _, failure?, expiry?) = deepSeekStatus,
              now() >= expiry else { return false }
        removeDeepSeekProvider()
        deepSeekStatus = .failed(failure)
        return true
    }

    private func removeDeepSeekProvider() {
        providers.removeAll { $0.providerId.caseInsensitiveCompare("deepseek") == .orderedSame }
    }

    private func applyGLM(_ provider: ProviderUsage) {
        var fresh = providers
        replace(provider, in: &fresh)
        commit(fresh)
        glmStatus = .live(fetchedAt: provider.fetchedAt ?? now())
        logger.info("GLM direct refresh succeeded")
    }

    private func applyGLMFailure(_ error: GLMErrorKind) {
        logger.info("GLM direct refresh failed: \(String(describing: error), privacy: .public)")
        switch error {
        case .unauthorized:
            removeGLMProvider()
            pendingGLMAPIKey = nil
            // Suppress the rejected credential before touching Keychain so a
            // deletion failure cannot cause periodic refreshes to resend it.
            suppressStoredGLMCredential = true
            do {
                try glmCredentials.deleteAPIKey()
                suppressStoredGLMCredential = false
                glmStatus = .failed(error)
            } catch {
                glmStatus = .failed(.credentialStoreFailure)
            }
        case .keyMissing, .invalidLocalKey, .credentialStoreFailure, .clientRejected:
            removeGLMProvider()
            glmStatus = .failed(error)
        case .networkFailure, .rateLimited, .serverUnavailable,
             .unexpectedHTTPStatus, .redirectRejected, .responseTooLarge,
             .malformedResponse, .quotaMissing:
            // Quota providers keep the last good data on transient failures,
            // matching the Claude/Kimi behavior; no contract cache is kept.
            glmStatus = .failed(error)
        }
        setFailureMessageIfNeeded()
    }

    private func removeGLMProvider() {
        providers.removeAll { $0.providerId.caseInsensitiveCompare("glm") == .orderedSame }
    }

    private nonisolated static func mapGLMError(_ error: GLMClientError) -> GLMErrorKind {
        switch error {
        case .keyMissing: .keyMissing
        case .invalidLocalKey: .invalidLocalKey
        case .unauthorized: .unauthorized
        case .clientRejected: .clientRejected
        case .rateLimited: .rateLimited
        case .serverUnavailable: .serverUnavailable
        case .unexpectedHTTPStatus: .unexpectedHTTPStatus
        case .networkFailure: .networkFailure
        case .redirectRejected: .redirectRejected
        case .responseTooLarge: .responseTooLarge
        case .malformedResponse: .malformedResponse
        case .quotaMissing: .quotaMissing
        }
    }

    private nonisolated static func mapDeepSeekError(_ error: DeepSeekClientError) -> DeepSeekErrorKind {
        switch error {
        case .keyMissing: .keyMissing
        case .invalidLocalKey: .invalidLocalKey
        case .unauthorized: .unauthorized
        case .clientRejected: .clientRejected
        case .rateLimited: .rateLimited
        case .serverUnavailable: .serverUnavailable
        case .unexpectedHTTPStatus: .unexpectedHTTPStatus
        case .networkFailure: .networkFailure
        case .redirectRejected: .redirectRejected
        case .responseTooLarge: .responseTooLarge
        case .malformedResponse: .malformedResponse
        case .cnyBalanceMissing: .cnyBalanceMissing
        }
    }

    private func replace(_ provider: ProviderUsage, in providers: inout [ProviderUsage]) {
        providers.removeAll { $0.providerId.caseInsensitiveCompare(provider.providerId) == .orderedSame }
        providers.append(provider)
    }

    private func commit(_ fresh: [ProviderUsage]) {
        let sorted = fresh.sorted {
            let leftRank = providerSortRank($0.providerId)
            let rightRank = providerSortRank($1.providerId)
            if leftRank != rightRank { return leftRank < rightRank }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        providers = sorted
        lastUpdated = now()
        errorMessageKey = nil
    }

    private func setFailureMessageIfNeeded() {
        guard providers.isEmpty else { return }
        errorMessageKey = "error.quotaUnavailable"
    }

    private func providerSortRank(_ providerId: String) -> Int {
        switch providerId.lowercased() {
        case "codex": 0
        case "claude": 1
        case "kimi": 2
        case "glm": 3
        case "deepseek": 4
        default: 5
        }
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

        let kimiHome = ProcessInfo.processInfo.environment["KIMI_CODE_HOME"].flatMap { value in
            value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
        } ?? home.appendingPathComponent(".kimi-code", isDirectory: true)
        let kimiDirectory = kimiHome.appendingPathComponent("sessions", isDirectory: true)
        if hasRecentlyModifiedJSONL(in: kimiDirectory, now: now) { active.insert("kimi") }
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
