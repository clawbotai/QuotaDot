import Foundation
import Security
import Testing
@testable import QuotaDot

struct DeepSeekTests {
    @Test @MainActor func credentialManagerStoresAndDeletesOnlyThroughInjectedKeychain() throws {
        let keychain = InMemoryDeepSeekCredentialStore()
        let credentials = DeepSeekCredentialManager(store: keychain)
        #expect(!credentials.hasStoredAPIKey)

        try credentials.saveAPIKey("sk-test")
        #expect(credentials.hasStoredAPIKey)
        #expect(try credentials.loadAPIKey() == "sk-test")

        try credentials.deleteAPIKey()
        #expect(!credentials.hasStoredAPIKey)
        #expect(try credentials.loadAPIKey() == nil)
    }

    @Test func strictlyValidatesPastedAPIKeysBeforeNetwork() throws {
        #expect(try DeepSeekDirectClient.validatedAPIKey("  sk-test  ") == "sk-test")
        for invalid in ["", "   ", "line\nbreak", String(repeating: "x", count: 8_193)] {
            #expect(throws: DeepSeekClientError.invalidLocalKey) {
                try DeepSeekDirectClient.validatedAPIKey(invalid)
            }
        }
    }

    @Test func parsesOfficialCNYBalanceAndBuildsAuthorizedRequest() async throws {
        let recorder = RequestRecorder()
        let responseData = #"{"is_available":true,"balance_infos":[{"currency":"USD","topped_up_balance":"4.00"},{"currency":"CNY","topped_up_balance":"12.35"}]}"#.data(using: .utf8)!
        let transport = ClosureDeepSeekTransport { request, maximumBytes in
            await recorder.record(request: request, maximumBytes: maximumBytes)
            return (responseData, Self.httpResponse(status: 200))
        }
        let client = DeepSeekDirectClient(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let provider = try await client.fetch(apiKey: "  sk-test  ")
        #expect(provider.providerId == "deepseek")
        #expect(provider.lines.isEmpty)
        #expect(provider.balance?.currency == "CNY")
        #expect(provider.balance?.toppedUp == Decimal(string: "12.35"))
        #expect(provider.balance?.isAvailable == true)
        #expect(provider.fetchedAt == Date(timeIntervalSince1970: 1_700_000_000))
        let recorded = await recorder.snapshot()
        #expect(recorded.authorization == "Bearer sk-test")
        #expect(recorded.maximumBytes == 1_048_576)
        #expect(recorded.url == "https://api.deepseek.com/user/balance")
    }

    @Test func zeroTopUpBalanceCanStillBeOfficiallyAvailable() async throws {
        let responseData = #"{"is_available":true,"balance_infos":[{"currency":"CNY","topped_up_balance":"0.00"}]}"#.data(using: .utf8)!
        let client = DeepSeekDirectClient(
            transport: ClosureDeepSeekTransport { _, _ in (responseData, Self.httpResponse(status: 200)) }
        )
        let provider = try await client.fetch(apiKey: "key")
        #expect(provider.balance?.toppedUp == 0)
        #expect(provider.balance?.isAvailable == true)
    }

    @Test func rejectsInvalidKeysBeforeNetwork() async {
        let recorder = RequestRecorder()
        let transport = ClosureDeepSeekTransport { request, maximumBytes in
            await recorder.record(request: request, maximumBytes: maximumBytes)
            return (Data(), Self.httpResponse(status: 200))
        }
        let client = DeepSeekDirectClient(transport: transport)
        await #expect(throws: DeepSeekClientError.invalidLocalKey) {
            try await client.fetch(apiKey: "  ")
        }
        #expect(await recorder.snapshot().count == 0)
    }

    @Test func strictlyValidatesMoneyStrings() throws {
        #expect(try DeepSeekDirectClient.parseCNY("0.00") == 0)
        #expect(try DeepSeekDirectClient.parseCNY("12345678901234567890123456.78") == Decimal(string: "12345678901234567890123456.78"))
        for invalid in ["-1.00", "+1.00", "1.234", "12.3abc", "1,000.00", "1e2", "NaN", "Infinity", "123456789012345678901234567.89"] {
            #expect(throws: DeepSeekClientError.malformedResponse) {
                try DeepSeekDirectClient.parseCNY(invalid)
            }
        }
    }

    @Test func mapsHTTPAndContractFailures() async {
        for (status, expected) in [(401, DeepSeekClientError.unauthorized), (429, .rateLimited), (500, .serverUnavailable), (418, .clientRejected)] {
            let client = DeepSeekDirectClient(
                transport: ClosureDeepSeekTransport { _, _ in (Data(), Self.httpResponse(status: status)) }
            )
            await #expect(throws: expected) {
                try await client.fetch(apiKey: "key")
            }
        }

        let noCNY = #"{"is_available":true,"balance_infos":[{"currency":"USD","topped_up_balance":"4.00"}]}"#.data(using: .utf8)!
        let client = DeepSeekDirectClient(
            transport: ClosureDeepSeekTransport { _, _ in (noCNY, Self.httpResponse(status: 200)) }
        )
        await #expect(throws: DeepSeekClientError.cnyBalanceMissing) {
            try await client.fetch(apiKey: "key")
        }

        let duplicateCNY = #"{"is_available":true,"balance_infos":[{"currency":"CNY","topped_up_balance":"1.00"},{"currency":"cny","topped_up_balance":"2.00"}]}"#.data(using: .utf8)!
        let duplicateClient = DeepSeekDirectClient(
            transport: ClosureDeepSeekTransport { _, _ in (duplicateCNY, Self.httpResponse(status: 200)) }
        )
        await #expect(throws: DeepSeekClientError.cnyBalanceMissing) {
            try await duplicateClient.fetch(apiKey: "key")
        }

        for boundaryError in [DeepSeekClientError.redirectRejected, .responseTooLarge] {
            let boundaryClient = DeepSeekDirectClient(
                transport: ClosureDeepSeekTransport { _, _ in throw boundaryError }
            )
            await #expect(throws: boundaryError) {
                try await boundaryClient.fetch(apiKey: "key")
            }
        }
    }

    @Test func realURLSessionTransportRejectsRedirectAndBoundsBodiesWithoutMaskingAuth() async {
        let transport = URLSessionDeepSeekTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DeepSeekURLProtocolStub.self]
            return configuration
        }
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.setValue("Bearer test-secret", forHTTPHeaderField: "Authorization")

        DeepSeekURLProtocolStub.install(.redirect(to: URL(string: "https://example.invalid/steal")!))
        await #expect(throws: DeepSeekClientError.redirectRejected) {
            try await transport.data(for: request, maximumBytes: 8)
        }
        let redirectRequests = DeepSeekURLProtocolStub.recordedRequests()
        #expect(redirectRequests.count == 1)
        #expect(redirectRequests.first?.url?.host == "api.deepseek.com")

        DeepSeekURLProtocolStub.install(.response(
            status: 401,
            headers: ["Content-Length": "9999"],
            chunks: []
        ))
        await #expect(throws: DeepSeekClientError.unauthorized) {
            try await transport.data(for: request, maximumBytes: 8)
        }

        DeepSeekURLProtocolStub.install(.response(
            status: 200,
            headers: ["Content-Length": "9"],
            chunks: []
        ))
        await #expect(throws: DeepSeekClientError.responseTooLarge) {
            try await transport.data(for: request, maximumBytes: 8)
        }

        DeepSeekURLProtocolStub.install(.response(
            status: 200,
            headers: [:],
            chunks: [Data(repeating: 0x61, count: 5), Data(repeating: 0x62, count: 4)]
        ))
        await #expect(throws: DeepSeekClientError.responseTooLarge) {
            try await transport.data(for: request, maximumBytes: 8)
        }
    }

    @Test func formatsExactAndCompactCNY() {
        #expect(QuotaFormatters.cny(Decimal(string: "12.35")!) == "¥12.35")
        #expect(QuotaFormatters.cny(0) == "¥0.00")
        #expect(QuotaFormatters.compactCNY(Decimal(string: "1234.56")!) == "¥1.2k")
        #expect(QuotaFormatters.compactCNY(Decimal(string: "1234567.89")!) == "¥1.2M")
        #expect(QuotaFormatters.compactCNY(Decimal(string: "999999.99")!) == "¥1M")
        #expect(QuotaFormatters.compactCNY(Decimal(string: "1234567890.12")!) == "¥1.2B")
        #expect(QuotaFormatters.compactCNY(Decimal(string: "999900000001")!) == "¥999B+")
    }

    @Test @MainActor func storeCachesTransientErrorsAndClearsUnauthorizedData() async {
        let keychain = InMemoryDeepSeekCredentialStore(apiKey: "stored-key")
        let credentials = DeepSeekCredentialManager(store: keychain)
        let provider = Self.provider(amount: "12.35", fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let client = SequenceDeepSeekClient(results: [.success(provider), .failure(.networkFailure), .failure(.unauthorized)])
        let store = QuotaStore(deepSeekCredentials: credentials, deepSeekClient: client, now: { Date(timeIntervalSince1970: 1_700_000_100) })

        store.refreshDeepSeek()
        await settle(store)
        #expect(store.deepSeekProvider?.balance?.toppedUp == Decimal(string: "12.35"))
        #expect(store.deepSeekStatus == .live(fetchedAt: provider.fetchedAt!))

        store.refreshDeepSeek()
        await settle(store)
        guard case let .cached(_, currentError, _, _) = store.deepSeekStatus else {
            Issue.record("Expected cached DeepSeek state")
            return
        }
        #expect(currentError == .networkFailure)
        #expect(store.deepSeekProvider != nil)

        store.refreshDeepSeek()
        await settle(store)
        #expect(store.deepSeekStatus == .failed(.unauthorized))
        #expect(store.deepSeekProvider == nil)
        #expect(keychain.currentAPIKey == nil)
    }

    @Test @MainActor func contractCacheExpiresEvenWhenFollowedByTransientFailure() async {
        let credentials = DeepSeekCredentialManager(store: InMemoryDeepSeekCredentialStore(apiKey: "stored-key"))
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MutableClock(fetchedAt.addingTimeInterval(60))
        let provider = Self.provider(amount: "5.00", fetchedAt: fetchedAt)
        let client = SequenceDeepSeekClient(results: [
            .success(provider),
            .failure(.responseTooLarge),
            .failure(.networkFailure)
        ])
        let store = QuotaStore(deepSeekCredentials: credentials, deepSeekClient: client, now: { clock.value })

        store.refreshDeepSeek()
        await settle(store)
        store.refreshDeepSeek()
        await settle(store)
        guard case let .cached(_, _, contractFailure, expiry) = store.deepSeekStatus else {
            Issue.record("Expected contract cache")
            return
        }
        #expect(contractFailure == .responseTooLarge)
        #expect(expiry == fetchedAt.addingTimeInterval(24 * 60 * 60))

        clock.value = fetchedAt.addingTimeInterval(24 * 60 * 60 + 1)
        store.refreshDeepSeek()
        await settle(store)
        #expect(store.deepSeekProvider == nil)
        // Expiry removes the stale contract cache, then the same refresh attempt
        // continues to the queued transient request instead of being swallowed.
        #expect(store.deepSeekStatus == .failed(.networkFailure))
    }

    @Test @MainActor func generationPreventsABAStaleWriteback() async {
        let credentials = DeepSeekCredentialManager(store: InMemoryDeepSeekCredentialStore(apiKey: "key-a"))
        let client = ControlledDeepSeekClient()
        let store = QuotaStore(deepSeekCredentials: credentials, deepSeekClient: client)

        store.refreshDeepSeek()
        await waitForRequests(client, count: 1)
        #expect(store.connectDeepSeek(apiKey: "key-b"))
        await waitForRequests(client, count: 2)
        #expect(store.connectDeepSeek(apiKey: "key-a"))
        await waitForRequests(client, count: 3)

        await client.succeed(index: 0, provider: Self.provider(amount: "1.00"))
        await client.succeed(index: 1, provider: Self.provider(amount: "2.00"))
        await client.succeed(index: 2, provider: Self.provider(amount: "3.00"))
        await settle(store)

        #expect(store.deepSeekProvider?.balance?.toppedUp == Decimal(string: "3.00"))
        #expect(!store.isRefreshing)
    }

    @Test @MainActor func missingKeychainCredentialDoesNotStartNetworkRequest() async {
        let credentials = DeepSeekCredentialManager(store: InMemoryDeepSeekCredentialStore())
        let client = CountingDeepSeekClient()
        let store = QuotaStore(deepSeekCredentials: credentials, deepSeekClient: client)

        store.refreshDeepSeek()
        #expect(await client.requestCount == 0)
        #expect(store.deepSeekStatus == .failed(.keyMissing))
    }

    @Test @MainActor func unauthorizedDeleteFailureSuppressesRejectedCredential() async {
        let keychain = InMemoryDeepSeekCredentialStore(apiKey: "rejected-key")
        keychain.failDelete = true
        let credentials = DeepSeekCredentialManager(store: keychain)
        let client = SequenceDeepSeekClient(results: [.failure(.unauthorized), .failure(.networkFailure)])
        let store = QuotaStore(deepSeekCredentials: credentials, deepSeekClient: client)

        store.refreshDeepSeek()
        await settle(store)
        #expect(store.deepSeekStatus == .failed(.credentialStoreFailure))
        #expect(keychain.currentAPIKey == "rejected-key")
        #expect(await client.requestCount == 1)

        store.refreshDeepSeek()
        #expect(await client.requestCount == 1)
        #expect(store.deepSeekStatus == .failed(.credentialStoreFailure))
    }

    @Test @MainActor func pendingCredentialCanBeDisconnectedAfterTransientFailure() async {
        let keychain = InMemoryDeepSeekCredentialStore()
        let credentials = DeepSeekCredentialManager(store: keychain)
        let client = SequenceDeepSeekClient(results: [.failure(.networkFailure)])
        let store = QuotaStore(deepSeekCredentials: credentials, deepSeekClient: client)

        #expect(store.connectDeepSeek(apiKey: "pending-key"))
        await settle(store)
        #expect(store.hasPendingDeepSeekCredential)
        #expect(keychain.currentAPIKey == nil)

        #expect(store.disconnectDeepSeek())
        #expect(!store.hasPendingDeepSeekCredential)
        #expect(keychain.currentAPIKey == nil)
    }

    @Test @MainActor func keychainLoadFailureDoesNotStartNetworkRequest() async {
        let keychain = InMemoryDeepSeekCredentialStore(apiKey: "stored-key")
        keychain.failLoad = true
        let credentials = DeepSeekCredentialManager(store: keychain)
        let client = CountingDeepSeekClient()
        let store = QuotaStore(deepSeekCredentials: credentials, deepSeekClient: client)

        store.refreshDeepSeek()
        #expect(await client.requestCount == 0)
        #expect(store.deepSeekStatus == .failed(.credentialStoreFailure))
    }

    @Test @MainActor func validatesBeforeSavingDisconnectsAndHandlesKeychainFailure() async {
        let keychain = InMemoryDeepSeekCredentialStore()
        let credentials = DeepSeekCredentialManager(store: keychain)
        let client = SequenceDeepSeekClient(results: [
            .success(Self.provider(amount: "7.00")),
            .success(Self.provider(amount: "8.00"))
        ])
        let store = QuotaStore(deepSeekCredentials: credentials, deepSeekClient: client)

        #expect(store.connectDeepSeek(apiKey: "new-key"))
        #expect(keychain.currentAPIKey == nil)
        await settle(store)
        #expect(keychain.currentAPIKey == "new-key")
        #expect(credentials.hasStoredAPIKey)

        #expect(store.disconnectDeepSeek())
        #expect(keychain.currentAPIKey == nil)
        #expect(store.deepSeekProvider == nil)

        keychain.failSave = true
        #expect(store.connectDeepSeek(apiKey: "cannot-save"))
        await settle(store)
        #expect(keychain.currentAPIKey == nil)
        #expect(store.deepSeekProvider == nil)
        #expect(store.deepSeekStatus == .failed(.credentialStoreFailure))
    }

    @Test func windowMetricsCoverEmptyQuotaAndBalanceCombinations() {
        #expect(QuotaWindowMetrics.expandedHeight(providers: [], hasCodexCredits: false) == 266)
        #expect(QuotaWindowMetrics.expandedHeight(providers: [Self.provider()], hasCodexCredits: false) == 228)
        let quota = ProviderUsage(providerId: "codex", displayName: "Codex", plan: nil, lines: [], fetchedAt: .now)
        #expect(QuotaWindowMetrics.expandedHeight(providers: [quota], hasCodexCredits: false) == 270)
        #expect(QuotaWindowMetrics.expandedHeight(providers: [quota], hasCodexCredits: true) == 298)
        #expect(QuotaWindowMetrics.expandedHeight(providers: [quota, Self.provider()], hasCodexCredits: false) == 403)
        #expect(QuotaWindowMetrics.compactWidth(providerCount: 3) == 172)
    }

    private static func provider(amount: String = "10.00", fetchedAt: Date = .now) -> ProviderUsage {
        ProviderUsage(
            providerId: "deepseek",
            displayName: "DeepSeek",
            plan: "API",
            lines: [],
            fetchedAt: fetchedAt,
            balance: ProviderBalance(currency: "CNY", toppedUp: Decimal(string: amount)!, isAvailable: true)
        )
    }

    private static func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.deepseek.com/user/balance")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    @MainActor private func settle(_ store: QuotaStore) async {
        for _ in 0..<1_000 {
            if !store.isRefreshing { return }
            await Task.yield()
        }
        Issue.record("Store did not settle")
    }

    @MainActor private func waitForRequests(_ client: ControlledDeepSeekClient, count: Int) async {
        for _ in 0..<1_000 {
            if await client.requestCount >= count { return }
            await Task.yield()
        }
        Issue.record("Expected \(count) controlled requests")
    }
}

private enum DeepSeekURLProtocolScenario: Sendable {
    case redirect(to: URL)
    case response(status: Int, headers: [String: String], chunks: [Data])
}

private final class DeepSeekURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var scenario: DeepSeekURLProtocolScenario = .response(status: 500, headers: [:], chunks: [])
    private var requests: [URLRequest] = []

    func install(_ scenario: DeepSeekURLProtocolScenario) {
        lock.withLock {
            self.scenario = scenario
            requests = []
        }
    }

    func record(_ request: URLRequest) -> DeepSeekURLProtocolScenario {
        lock.withLock {
            requests.append(request)
            return scenario
        }
    }

    func snapshot() -> [URLRequest] { lock.withLock { requests } }
}

private final class DeepSeekURLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let state = DeepSeekURLProtocolState()

    static func install(_ scenario: DeepSeekURLProtocolScenario) { state.install(scenario) }
    static func recordedRequests() -> [URLRequest] { state.snapshot() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch Self.state.record(request) {
        case let .redirect(target):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": target.absoluteString]
            )!
            var redirected = request
            redirected.url = target
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
        case let .response(status, headers, chunks):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

private final class InMemoryDeepSeekCredentialStore: DeepSeekCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var apiKey: String?
    private var shouldFailSave = false
    private var shouldFailLoad = false
    private var shouldFailDelete = false

    init(apiKey: String? = nil) { self.apiKey = apiKey }

    var currentAPIKey: String? { lock.withLock { apiKey } }
    var failSave: Bool {
        get { lock.withLock { shouldFailSave } }
        set { lock.withLock { shouldFailSave = newValue } }
    }
    var failLoad: Bool {
        get { lock.withLock { shouldFailLoad } }
        set { lock.withLock { shouldFailLoad = newValue } }
    }
    var failDelete: Bool {
        get { lock.withLock { shouldFailDelete } }
        set { lock.withLock { shouldFailDelete = newValue } }
    }

    func loadAPIKey() throws -> String? {
        try lock.withLock {
            if shouldFailLoad { throw DeepSeekCredentialError.keychain(errSecInteractionNotAllowed) }
            return apiKey
        }
    }

    func saveAPIKey(_ apiKey: String) throws {
        try lock.withLock {
            if shouldFailSave { throw DeepSeekCredentialError.keychain(errSecInteractionNotAllowed) }
            self.apiKey = apiKey
        }
    }

    func deleteAPIKey() throws {
        try lock.withLock {
            if shouldFailDelete { throw DeepSeekCredentialError.keychain(errSecInteractionNotAllowed) }
            apiKey = nil
        }
    }
}

private struct ClosureDeepSeekTransport: DeepSeekHTTPTransport {
    let handler: @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try await handler(request, maximumBytes)
    }
}

private actor RequestRecorder {
    private var request: URLRequest?
    private var maximumBytes = 0
    private var count = 0

    func record(request: URLRequest, maximumBytes: Int) {
        self.request = request
        self.maximumBytes = maximumBytes
        count += 1
    }

    func snapshot() -> (authorization: String?, maximumBytes: Int, url: String?, count: Int) {
        (request?.value(forHTTPHeaderField: "Authorization"), maximumBytes, request?.url?.absoluteString, count)
    }
}

private actor SequenceDeepSeekClient: DeepSeekUsageClient {
    private var results: [Result<ProviderUsage, DeepSeekClientError>]
    private(set) var requestCount = 0

    init(results: [Result<ProviderUsage, DeepSeekClientError>]) {
        self.results = results
    }

    func fetch(apiKey: String) async throws -> ProviderUsage {
        requestCount += 1
        guard !results.isEmpty else { throw DeepSeekClientError.networkFailure }
        return try results.removeFirst().get()
    }
}

private actor CountingDeepSeekClient: DeepSeekUsageClient {
    private(set) var requestCount = 0

    func fetch(apiKey: String) async throws -> ProviderUsage {
        requestCount += 1
        throw DeepSeekClientError.networkFailure
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(_ value: Date) { stored = value }

    var value: Date {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private actor ControlledDeepSeekClient: DeepSeekUsageClient {
    private var continuations: [CheckedContinuation<ProviderUsage, Error>] = []
    var requestCount: Int { continuations.count }

    func fetch(apiKey: String) async throws -> ProviderUsage {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func succeed(index: Int, provider: ProviderUsage) {
        continuations[index].resume(returning: provider)
    }
}
