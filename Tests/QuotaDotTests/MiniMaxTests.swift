import Foundation
import Security
import Testing
@testable import QuotaDot

struct MiniMaxTests {
    @Test @MainActor func credentialManagerStoresAndDeletesOnlyThroughInjectedKeychain() throws {
        let keychain = InMemoryMiniMaxCredentialStore()
        let credentials = MiniMaxCredentialManager(store: keychain)
        #expect(!credentials.hasStoredAPIKey)

        try credentials.saveAPIKey("minimax-test")
        #expect(credentials.hasStoredAPIKey)
        #expect(try credentials.loadAPIKey() == "minimax-test")

        try credentials.deleteAPIKey()
        #expect(!credentials.hasStoredAPIKey)
        #expect(try credentials.loadAPIKey() == nil)
    }

    @Test func strictlyValidatesPastedAPIKeysBeforeNetwork() throws {
        #expect(try MiniMaxDirectClient.validatedAPIKey("  minimax-test  ") == "minimax-test")
        for invalid in ["", "   ", "line\nbreak", String(repeating: "x", count: 8_193)] {
            #expect(throws: MiniMaxClientError.invalidLocalKey) {
                try MiniMaxDirectClient.validatedAPIKey(invalid)
            }
        }
    }

    @Test func parsesGeneralModelRemainsAndBuildsAuthorizedRequest() async throws {
        let recorder = MiniMaxRequestRecorder()
        let responseData = """
        {"base_resp":{"status_code":0,"status_msg":""},"model_remains":[
          {"model_name":"video","current_interval_remaining_percent":55.0},
          {"model_name":"general",
           "current_interval_remaining_percent":80.0,"end_time":1700003600000,
           "current_weekly_status":1,
           "current_weekly_remaining_percent":92.5,"weekly_end_time":1700604800000}
        ]}
        """.data(using: .utf8)!
        let transport = ClosureMiniMaxTransport { request, maximumBytes in
            await recorder.record(request: request, maximumBytes: maximumBytes)
            return (responseData, Self.httpResponse(status: 200))
        }
        let client = MiniMaxDirectClient(
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let provider = try await client.fetch(apiKey: "  minimax-key  ")
        #expect(provider.providerId == "minimax")
        #expect(provider.displayName == "MiniMax")
        #expect(provider.plan == nil)
        #expect(provider.balance == nil)
        #expect(provider.fetchedAt == Date(timeIntervalSince1970: 1_700_000_000))

        let session = try #require(provider.session)
        #expect(session.used == 20)
        #expect(session.limit == 100)
        #expect(session.periodDurationMs == 18_000_000)
        #expect(session.resetsAt == Date(timeIntervalSince1970: 1_700_003_600))

        let weekly = try #require(provider.weekly)
        #expect(weekly.used == 7.5)
        #expect(weekly.periodDurationMs == 604_800_000)
        #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_700_604_800))

        let recorded = await recorder.snapshot()
        #expect(recorded.authorization == "Bearer minimax-key")
        #expect(recorded.maximumBytes == 1_048_576)
        #expect(recorded.urls == ["https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains"])
    }

    @Test func skipsUncappedWeeklyWindows() async throws {
        let responseData = """
        {"base_resp":{"status_code":0},"model_remains":[
          {"model_name":"general",
           "current_interval_remaining_percent":40.0,"end_time":1700003600000,
           "current_weekly_status":3,
           "current_weekly_remaining_percent":100.0,"weekly_end_time":1700604800000}
        ]}
        """.data(using: .utf8)!
        let client = MiniMaxDirectClient(
            transport: ClosureMiniMaxTransport { _, _ in (responseData, Self.httpResponse(status: 200)) }
        )
        let provider = try await client.fetch(apiKey: "key")
        let session = try #require(provider.session)
        #expect(session.used == 60)
        #expect(provider.weekly == nil)
    }

    @Test func clampsOutOfRangePercentages() async throws {
        let responseData = """
        {"base_resp":{"status_code":0},"model_remains":[
          {"model_name":"general",
           "current_interval_remaining_percent":140.0,
           "current_weekly_status":1,"current_weekly_remaining_percent":-5.0}
        ]}
        """.data(using: .utf8)!
        let client = MiniMaxDirectClient(
            transport: ClosureMiniMaxTransport { _, _ in (responseData, Self.httpResponse(status: 200)) }
        )
        let provider = try await client.fetch(apiKey: "key")
        #expect(provider.session?.used == 0)
        #expect(provider.weekly?.used == 100)
    }

    @Test func missingGeneralModelThrowsQuotaMissing() async {
        let empty = #"{"base_resp":{"status_code":0},"model_remains":[]}"#.data(using: .utf8)!
        let videoOnly = #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"video","current_interval_remaining_percent":55.0}]}"#.data(using: .utf8)!
        let noPercent = #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"general","end_time":1700003600000}]}"#.data(using: .utf8)!
        for body in [empty, videoOnly, noPercent] {
            let client = MiniMaxDirectClient(
                transport: ClosureMiniMaxTransport { _, _ in (body, Self.httpResponse(status: 200)) }
            )
            await #expect(throws: MiniMaxClientError.quotaMissing) {
                try await client.fetch(apiKey: "key")
            }
        }
    }

    @Test func inBandBaseRespFailuresMapToErrors() async {
        for (statusCode, expected) in [(1004, MiniMaxClientError.unauthorized), (1026, .clientRejected)] {
            let body = #"{"base_resp":{"status_code":\#(statusCode),"status_msg":"rejected"}}"#.data(using: .utf8)!
            let client = MiniMaxDirectClient(
                transport: ClosureMiniMaxTransport { _, _ in (body, Self.httpResponse(status: 200)) }
            )
            await #expect(throws: expected) {
                try await client.fetch(apiKey: "key")
            }
        }
    }

    @Test func mapsHTTPStatusFailures() async {
        for (status, expected) in [(401, MiniMaxClientError.unauthorized), (403, MiniMaxClientError.unauthorized), (429, .rateLimited), (500, .serverUnavailable), (418, .clientRejected)] {
            let client = MiniMaxDirectClient(
                transport: ClosureMiniMaxTransport { _, _ in (Data(), Self.httpResponse(status: status)) }
            )
            await #expect(throws: expected) {
                try await client.fetch(apiKey: "key")
            }
        }

        let malformedClient = MiniMaxDirectClient(
            transport: ClosureMiniMaxTransport { _, _ in (Data("not json".utf8), Self.httpResponse(status: 200)) }
        )
        await #expect(throws: MiniMaxClientError.malformedResponse) {
            try await malformedClient.fetch(apiKey: "key")
        }
    }

    @Test func rejectsInvalidKeysBeforeNetwork() async {
        let recorder = MiniMaxRequestRecorder()
        let client = MiniMaxDirectClient(
            transport: ClosureMiniMaxTransport { request, maximumBytes in
                await recorder.record(request: request, maximumBytes: maximumBytes)
                return (Data(), Self.httpResponse(status: 200))
            }
        )
        await #expect(throws: MiniMaxClientError.invalidLocalKey) {
            try await client.fetch(apiKey: "  ")
        }
        #expect(await recorder.snapshot().urls.isEmpty)
    }

    @Test func fallsBackToGlobalHostAfterRegionalFailure() async throws {
        let recorder = MiniMaxRequestRecorder()
        let responseData = """
        {"base_resp":{"status_code":0},"model_remains":[
          {"model_name":"general","current_interval_remaining_percent":90.0}
        ]}
        """.data(using: .utf8)!
        let transport = ClosureMiniMaxTransport { request, _ in
            await recorder.record(request: request, maximumBytes: 0)
            if request.url?.host == MiniMaxDirectClient.cnHost {
                throw MiniMaxClientError.networkFailure
            }
            return (responseData, Self.httpResponse(status: 200))
        }
        let client = MiniMaxDirectClient(transport: transport)

        let provider = try await client.fetch(apiKey: "key")
        #expect(provider.session?.used == 10)
        let recorded = await recorder.snapshot()
        #expect(recorded.urls == [
            "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains",
            "https://api.minimax.io/v1/api/openplatform/coding_plan/remains"
        ])

        // A later refresh prefers the host that last succeeded.
        _ = try await client.fetch(apiKey: "key")
        let secondRun = await recorder.snapshot()
        #expect(secondRun.urls.last == "https://api.minimax.io/v1/api/openplatform/coding_plan/remains")
    }

    @Test func nonTransientFailuresDoNotFallBack() async {
        let recorder = MiniMaxRequestRecorder()
        let client = MiniMaxDirectClient(
            transport: ClosureMiniMaxTransport { request, _ in
                await recorder.record(request: request, maximumBytes: 0)
                throw MiniMaxClientError.quotaMissing
            }
        )
        await #expect(throws: MiniMaxClientError.quotaMissing) {
            try await client.fetch(apiKey: "key")
        }
        #expect(await recorder.snapshot().urls.count == 1)
    }

    @Test @MainActor func connectSavesKeyOnlyAfterSuccessfulFetch() async {
        let keychain = InMemoryMiniMaxCredentialStore()
        let credentials = MiniMaxCredentialManager(store: keychain)
        let client = SequenceMiniMaxClient(results: [.success(Self.provider())])
        let store = QuotaStore(miniMaxCredentials: credentials, miniMaxClient: client)

        #expect(store.connectMiniMax(apiKey: "new-minimax-key"))
        #expect(keychain.currentAPIKey == nil)
        await settle(store)
        #expect(keychain.currentAPIKey == "new-minimax-key")
        #expect(credentials.hasStoredAPIKey)
        #expect(store.miniMaxProvider?.session?.used == 20)
        #expect(store.miniMaxStatus == .live(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)))

        #expect(store.disconnectMiniMax())
        #expect(keychain.currentAPIKey == nil)
        #expect(store.miniMaxProvider == nil)
        #expect(store.miniMaxStatus == .idle)
    }

    @Test @MainActor func transientFailureKeepsExistingQuotaData() async {
        let keychain = InMemoryMiniMaxCredentialStore(apiKey: "stored-key")
        let credentials = MiniMaxCredentialManager(store: keychain)
        let client = SequenceMiniMaxClient(results: [.success(Self.provider()), .failure(.networkFailure)])
        let store = QuotaStore(miniMaxCredentials: credentials, miniMaxClient: client)

        store.refreshMiniMax()
        await settle(store)
        #expect(store.miniMaxProvider?.session?.used == 20)
        #expect(store.miniMaxStatus == .live(fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)))

        store.refreshMiniMax()
        await settle(store)
        #expect(store.miniMaxStatus == .failed(.networkFailure))
        // Quota providers keep the last good data on transient failures.
        #expect(store.miniMaxProvider?.session?.used == 20)
        #expect(keychain.currentAPIKey == "stored-key")
    }

    @Test @MainActor func unauthorizedClearsProviderAndKeychain() async {
        let keychain = InMemoryMiniMaxCredentialStore(apiKey: "stored-key")
        let credentials = MiniMaxCredentialManager(store: keychain)
        let client = SequenceMiniMaxClient(results: [.success(Self.provider()), .failure(.unauthorized)])
        let store = QuotaStore(miniMaxCredentials: credentials, miniMaxClient: client)

        store.refreshMiniMax()
        await settle(store)
        #expect(store.miniMaxProvider != nil)

        store.refreshMiniMax()
        await settle(store)
        #expect(store.miniMaxStatus == .failed(.unauthorized))
        #expect(store.miniMaxProvider == nil)
        #expect(keychain.currentAPIKey == nil)
    }

    @Test @MainActor func missingKeychainCredentialDoesNotStartNetworkRequest() async {
        let credentials = MiniMaxCredentialManager(store: InMemoryMiniMaxCredentialStore())
        let client = CountingMiniMaxClient()
        let store = QuotaStore(miniMaxCredentials: credentials, miniMaxClient: client)

        store.refreshMiniMax()
        #expect(await client.requestCount == 0)
        #expect(store.miniMaxStatus == .failed(.keyMissing))
    }

    @Test @MainActor func invalidLocalKeyIsRejectedBeforeConnect() async {
        let credentials = MiniMaxCredentialManager(store: InMemoryMiniMaxCredentialStore())
        let client = CountingMiniMaxClient()
        let store = QuotaStore(miniMaxCredentials: credentials, miniMaxClient: client)

        #expect(!store.connectMiniMax(apiKey: "   "))
        #expect(await client.requestCount == 0)
        #expect(!store.hasPendingMiniMaxCredential)
    }

    private static func provider() -> ProviderUsage {
        ProviderUsage(
            providerId: "minimax",
            displayName: "MiniMax",
            plan: nil,
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
            url: URL(string: "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains")!,
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

private final class InMemoryMiniMaxCredentialStore: MiniMaxCredentialStoring, @unchecked Sendable {
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

private struct ClosureMiniMaxTransport: BoundedHTTPTransporting {
    let handler: @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    init(handler: @escaping @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try await handler(request, maximumBytes)
    }
}

private actor MiniMaxRequestRecorder {
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

private actor SequenceMiniMaxClient: MiniMaxUsageClient {
    private var results: [Result<ProviderUsage, MiniMaxClientError>]
    private(set) var requestCount = 0

    init(results: [Result<ProviderUsage, MiniMaxClientError>]) {
        self.results = results
    }

    func fetch(apiKey: String) async throws -> ProviderUsage {
        requestCount += 1
        guard !results.isEmpty else { throw MiniMaxClientError.networkFailure }
        return try results.removeFirst().get()
    }
}

private actor CountingMiniMaxClient: MiniMaxUsageClient {
    private(set) var requestCount = 0

    func fetch(apiKey: String) async throws -> ProviderUsage {
        requestCount += 1
        throw MiniMaxClientError.networkFailure
    }
}
