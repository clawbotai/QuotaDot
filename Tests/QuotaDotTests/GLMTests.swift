import Foundation
import Security
import Testing
@testable import QuotaDot

struct GLMTests {
    @Test @MainActor func credentialManagerStoresAndDeletesOnlyThroughInjectedKeychain() throws {
        let keychain = InMemoryGLMCredentialStore()
        let credentials = GLMCredentialManager(store: keychain)
        #expect(!credentials.hasStoredAPIKey)

        try credentials.saveAPIKey("glm-test")
        #expect(credentials.hasStoredAPIKey)
        #expect(try credentials.loadAPIKey() == "glm-test")

        try credentials.deleteAPIKey()
        #expect(!credentials.hasStoredAPIKey)
        #expect(try credentials.loadAPIKey() == nil)
    }

    @Test func strictlyValidatesPastedAPIKeysBeforeNetwork() throws {
        #expect(try GLMDirectClient.validatedAPIKey("  glm-test  ") == "glm-test")
        for invalid in ["", "   ", "line\nbreak", String(repeating: "x", count: 8_193)] {
            #expect(throws: GLMClientError.invalidLocalKey) {
                try GLMDirectClient.validatedAPIKey(invalid)
            }
        }
    }

    @Test func parsesTokenLimitsAndBuildsAuthorizedRequest() async throws {
        let recorder = GLMRequestRecorder()
        let responseData = """
        {"data":{"level":"pro","limits":[
          {"type":"TOKENS_LIMIT","unit":3,"percentage":42.0,"nextResetTime":1700003600000},
          {"type":"TOKENS_LIMIT","unit":6,"percentage":7.5,"nextResetTime":1700604800000}
        ]}}
        """.data(using: .utf8)!
        let transport = ClosureGLMTransport { request, maximumBytes in
            await recorder.record(request: request, maximumBytes: maximumBytes)
            return (responseData, Self.httpResponse(status: 200))
        }
        let client = GLMDirectClient(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let provider = try await client.fetch(apiKey: "  glm-key  ")
        #expect(provider.providerId == "glm")
        #expect(provider.displayName == "GLM")
        #expect(provider.plan == "pro")
        #expect(provider.balance == nil)
        #expect(provider.fetchedAt == Date(timeIntervalSince1970: 1_700_000_000))

        let session = try #require(provider.session)
        #expect(session.used == 42)
        #expect(session.limit == 100)
        #expect(session.periodDurationMs == 18_000_000)
        #expect(session.resetsAt == Date(timeIntervalSince1970: 1_700_003_600))

        let weekly = try #require(provider.weekly)
        #expect(weekly.used == 7.5)
        #expect(weekly.periodDurationMs == 604_800_000)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_700_604_800))

        let recorded = await recorder.snapshot()
        #expect(recorded.authorization == "glm-key")
        #expect(recorded.maximumBytes == 1_048_576)
        #expect(recorded.urls == ["https://open.bigmodel.cn/api/monitor/usage/quota/limit"])
    }

    @Test func parsesCreditLimitsAndSkipsTimeLimits() async throws {
        let responseData = """
        {"data":{"level":"max","limits":[
          {"type":"TIME_LIMIT","unit":3,"percentage":99.0,"nextResetTime":1700003600000},
          {"type":"CREDIT_LIMIT","unit":6,"percentage":12.0}
        ]}}
        """.data(using: .utf8)!
        let client = GLMDirectClient(
            transport: ClosureGLMTransport { _, _ in (responseData, Self.httpResponse(status: 200)) }
        )
        let provider = try await client.fetch(apiKey: "key")
        #expect(provider.plan == "max")
        #expect(provider.session == nil)
        let weekly = try #require(provider.weekly)
        #expect(weekly.used == 12)
        #expect(weekly.resetsAt == nil)
    }

    @Test func clampsOutOfRangePercentages() async throws {
        let responseData = """
        {"data":{"level":"pro","limits":[
          {"type":"TOKENS_LIMIT","unit":3,"percentage":140.0,"nextResetTime":1700003600000},
          {"type":"TOKENS_LIMIT","unit":6,"percentage":-5.0,"nextResetTime":1700604800000}
        ]}}
        """.data(using: .utf8)!
        let client = GLMDirectClient(
            transport: ClosureGLMTransport { _, _ in (responseData, Self.httpResponse(status: 200)) }
        )
        let provider = try await client.fetch(apiKey: "key")
        #expect(provider.session?.used == 100)
        #expect(provider.weekly?.used == 0)
    }

    @Test func missingQuotaWindowsThrowQuotaMissing() async {
        let emptyLimits = #"{"data":{"level":"pro","limits":[]}}"#.data(using: .utf8)!
        let timeOnly = #"{"data":{"level":"pro","limits":[{"type":"TIME_LIMIT","unit":3,"percentage":1.0}]}}"#.data(using: .utf8)!
        for body in [emptyLimits, timeOnly] {
            let client = GLMDirectClient(
                transport: ClosureGLMTransport { _, _ in (body, Self.httpResponse(status: 200)) }
            )
            await #expect(throws: GLMClientError.quotaMissing) {
                try await client.fetch(apiKey: "key")
            }
        }
    }

    @Test func mapsHTTPStatusFailures() async {
        for (status, expected) in [(401, GLMClientError.unauthorized), (403, GLMClientError.unauthorized), (429, .rateLimited), (500, .serverUnavailable), (418, .clientRejected)] {
            let recorder = GLMRequestRecorder()
            let client = GLMDirectClient(
                transport: ClosureGLMTransport { request, _ in
                    await recorder.record(request: request, maximumBytes: 0)
                    return (Data(), Self.httpResponse(status: status))
                }
            )
            await #expect(throws: expected) {
                try await client.fetch(apiKey: "key")
            }
        }

        let malformedClient = GLMDirectClient(
            transport: ClosureGLMTransport { _, _ in (Data("not json".utf8), Self.httpResponse(status: 200)) }
        )
        await #expect(throws: GLMClientError.malformedResponse) {
            try await malformedClient.fetch(apiKey: "key")
        }
    }

    @Test func rejectsInvalidKeysBeforeNetwork() async {
        let recorder = GLMRequestRecorder()
        let client = GLMDirectClient(
            transport: ClosureGLMTransport { request, maximumBytes in
                await recorder.record(request: request, maximumBytes: maximumBytes)
                return (Data(), Self.httpResponse(status: 200))
            }
        )
        await #expect(throws: GLMClientError.invalidLocalKey) {
            try await client.fetch(apiKey: "  ")
        }
        #expect(await recorder.snapshot().urls.isEmpty)
    }

    @Test func fallsBackToGlobalHostAfterRegionalFailure() async throws {
        let recorder = GLMRequestRecorder()
        let responseData = """
        {"data":{"level":"pro","limits":[
          {"type":"TOKENS_LIMIT","unit":3,"percentage":10.0,"nextResetTime":1700003600000}
        ]}}
        """.data(using: .utf8)!
        let transport = ClosureGLMTransport { request, _ in
            await recorder.record(request: request, maximumBytes: 0)
            if request.url?.host == GLMDirectClient.cnHost {
                throw GLMClientError.networkFailure
            }
            return (responseData, Self.httpResponse(status: 200))
        }
        let client = GLMDirectClient(transport: transport)

        let provider = try await client.fetch(apiKey: "key")
        #expect(provider.session?.used == 10)
        let recorded = await recorder.snapshot()
        #expect(recorded.urls == [
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
            "https://api.z.ai/api/monitor/usage/quota/limit"
        ])

        // A later refresh prefers the host that last succeeded.
        _ = try await client.fetch(apiKey: "key")
        let secondRun = await recorder.snapshot()
        #expect(secondRun.urls.last == "https://api.z.ai/api/monitor/usage/quota/limit")
    }

    @Test func nonTransientFailuresDoNotFallBack() async {
        let recorder = GLMRequestRecorder()
        let client = GLMDirectClient(
            transport: ClosureGLMTransport { request, _ in
                await recorder.record(request: request, maximumBytes: 0)
                throw GLMClientError.quotaMissing
            }
        )
        await #expect(throws: GLMClientError.quotaMissing) {
            try await client.fetch(apiKey: "key")
        }
        #expect(await recorder.snapshot().urls.count == 1)
    }

    @Test @MainActor func connectSavesKeyOnlyAfterSuccessfulFetch() async {
        let keychain = InMemoryGLMCredentialStore()
        let credentials = GLMCredentialManager(store: keychain)
        let client = SequenceGLMClient(results: [.success(Self.provider())])
        let store = QuotaStore(glmCredentials: credentials, glmClient: client)

        #expect(store.connectGLM(apiKey: "new-glm-key"))
        #expect(keychain.currentAPIKey == nil)
        await settle(store)
        #expect(keychain.currentAPIKey == "new-glm-key")
        #expect(credentials.hasStoredAPIKey)
        #expect(store.glmProvider?.session?.used == 20)
        #expect(store.glmStatus == .live(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)))

        #expect(store.disconnectGLM())
        #expect(keychain.currentAPIKey == nil)
        #expect(store.glmProvider == nil)
        #expect(store.glmStatus == .idle)
    }

    @Test @MainActor func transientFailureKeepsExistingQuotaData() async {
        let keychain = InMemoryGLMCredentialStore(apiKey: "stored-key")
        let credentials = GLMCredentialManager(store: keychain)
        let client = SequenceGLMClient(results: [.success(Self.provider()), .failure(.networkFailure)])
        let store = QuotaStore(glmCredentials: credentials, glmClient: client)

        store.refreshGLM()
        await settle(store)
        #expect(store.glmProvider?.session?.used == 20)
        #expect(store.glmStatus == .live(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)))

        store.refreshGLM()
        await settle(store)
        #expect(store.glmStatus == .failed(.networkFailure))
        // Quota providers keep the last good data on transient failures.
        #expect(store.glmProvider?.session?.used == 20)
        #expect(keychain.currentAPIKey == "stored-key")
    }

    @Test @MainActor func unauthorizedClearsProviderAndKeychain() async {
        let keychain = InMemoryGLMCredentialStore(apiKey: "stored-key")
        let credentials = GLMCredentialManager(store: keychain)
        let client = SequenceGLMClient(results: [.success(Self.provider()), .failure(.unauthorized)])
        let store = QuotaStore(glmCredentials: credentials, glmClient: client)

        store.refreshGLM()
        await settle(store)
        #expect(store.glmProvider != nil)

        store.refreshGLM()
        await settle(store)
        #expect(store.glmStatus == .failed(.unauthorized))
        #expect(store.glmProvider == nil)
        #expect(keychain.currentAPIKey == nil)
    }

    @Test @MainActor func missingKeychainCredentialDoesNotStartNetworkRequest() async {
        let credentials = GLMCredentialManager(store: InMemoryGLMCredentialStore())
        let client = CountingGLMClient()
        let store = QuotaStore(glmCredentials: credentials, glmClient: client)

        store.refreshGLM()
        #expect(await client.requestCount == 0)
        #expect(store.glmStatus == .failed(.keyMissing))
    }

    @Test @MainActor func invalidLocalKeyIsRejectedBeforeConnect() async {
        let credentials = GLMCredentialManager(store: InMemoryGLMCredentialStore())
        let client = CountingGLMClient()
        let store = QuotaStore(glmCredentials: credentials, glmClient: client)

        #expect(!store.connectGLM(apiKey: "   "))
        #expect(await client.requestCount == 0)
        #expect(!store.hasPendingGLMCredential)
    }

    private static func provider() -> ProviderUsage {
        ProviderUsage(
            providerId: "glm",
            displayName: "GLM",
            plan: "pro",
            lines: [
                UsageLine(
                    type: "progress", label: "Session",
                    used: 20, limit: 100,
                    resetsAt: Date(timeIntervalSince1970: 1_700_003_600),
                    periodDurationMs: 5 * 3_600 * 1_000,
                    value: nil, subtitle: nil
                ),
                UsageLine(
                    type: "progress", label: "Weekly",
                    used: 5, limit: 100,
                    resetsAt: Date(timeIntervalSince1970: 1_700_604_800),
                    periodDurationMs: 7 * 24 * 3_600 * 1_000,
                    value: nil, subtitle: nil
                )
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static func httpResponse(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    @MainActor private func settle(_ store: QuotaStore) async {
        for _ in 0..<1_000 {
            if !store.isRefreshing { return }
            await Task.yield()
        }
        Issue.record("Store did not settle")
    }
}

private final class InMemoryGLMCredentialStore: GLMCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var apiKey: String?

    init(apiKey: String? = nil) { self.apiKey = apiKey }

    var currentAPIKey: String? { lock.withLock { apiKey } }

    func loadAPIKey() throws -> String? { lock.withLock { apiKey } }

    func saveAPIKey(_ apiKey: String) throws {
        lock.withLock { self.apiKey = apiKey }
    }

    func deleteAPIKey() throws {
        lock.withLock { apiKey = nil }
    }
}

private struct ClosureGLMTransport: BoundedHTTPTransporting {
    let handler: @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try await handler(request, maximumBytes)
    }
}

private actor GLMRequestRecorder {
    private var requests: [URLRequest] = []
    private var maximumBytes = 0

    func record(request: URLRequest, maximumBytes: Int) {
        requests.append(request)
        self.maximumBytes = maximumBytes
    }

    func snapshot() -> (authorization: String?, maximumBytes: Int, urls: [String]) {
        (
            requests.last?.value(forHTTPHeaderField: "Authorization"),
            maximumBytes,
            requests.compactMap { $0.url?.absoluteString }
        )
    }
}

private actor SequenceGLMClient: GLMUsageClient {
    private var results: [Result<ProviderUsage, GLMClientError>]
    private(set) var requestCount = 0

    init(results: [Result<ProviderUsage, GLMClientError>]) {
        self.results = results
    }

    func fetch(apiKey: String) async throws -> ProviderUsage {
        requestCount += 1
        guard !results.isEmpty else { throw GLMClientError.networkFailure }
        return try results.removeFirst().get()
    }
}

private actor CountingGLMClient: GLMUsageClient {
    private(set) var requestCount = 0

    func fetch(apiKey: String) async throws -> ProviderUsage {
        requestCount += 1
        throw GLMClientError.networkFailure
    }
}
