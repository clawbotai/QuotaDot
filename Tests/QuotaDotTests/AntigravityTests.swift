import Foundation
import Testing
@testable import QuotaDot

struct AntigravityTests {
    @Test func parsesModelPoolsWithoutInventingTimeWindows() throws {
        let data = Data(#"{"models":{"gemini-pro":{"quotaInfo":{"remainingFraction":0.8}},"gemini-flash":{"quotaInfo":{"remainingFraction":0.3,"resetTime":"2026-09-24T10:00:00Z"}},"claude-sonnet":{"quotaInfo":{"remainingFraction":0}},"claude-opus":{"quotaInfo":{"resetTime":"2026-09-24T10:00:00Z"}},"other-pro":{"quotaInfo":{"remainingFraction":0.01}}}}"#.utf8)
        let provider = try AntigravityUsageParser.provider(from: data, plan: "Pro", now: .now)
        #expect(provider.lines.map(\.label) == ["Gemini", "Claude"])
        #expect(abs(provider.lines[0].remainingPercent! - 0.3) < 0.0001)
        #expect(provider.lines[0].resetsAt != nil)
        #expect(provider.lines[1].remainingPercent == 0)
        #expect(provider.session == nil)
        #expect(provider.weekly == nil)
        #expect(provider.displayRemainingPercent == 0)
        #expect(provider.lowestRemainingPercent == 0)
    }

    @Test func missingQuotaIsNotFullOrExhausted() {
        for json in [#"{"models":{}}"#, #"{"models":{"gemini-pro":{"quotaInfo":{"resetTime":"2026-09-24T10:00:00Z"}}}}"#] {
            #expect(throws: AntigravityError.quotaUnavailable) {
                try AntigravityUsageParser.provider(from: Data(json.utf8), plan: nil, now: .now)
            }
        }
    }

    @Test func summaryPrefersRetrieveUserQuotaSummaryBuckets() throws {
        let data = Data("""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "description": "Models within this group: Gemini Flash, Gemini Pro",
              "buckets": [
                {"bucketId": "gemini-5h", "displayName": "Five Hour Limit Remaining", "window": "5h",
                 "resetTime": "2026-09-23T15:45:28Z", "remainingFraction": 0.3},
                {"bucketId": "gemini-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly",
                 "resetTime": "2026-09-29T12:08:59Z", "remainingFraction": 0.583}
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "description": "Models within this group: Claude Opus, Claude Sonnet, GPT-OSS",
              "buckets": [
                {"bucketId": "3p-5h", "displayName": "Five Hour Limit Remaining", "window": "5h",
                 "remainingFraction": 1.0},
                {"bucketId": "3p-weekly", "displayName": "Weekly Limit Remaining", "window": "weekly",
                 "resetTime": "2026-09-31T11:50:43Z", "remainingFraction": 0.886}
              ]
            }
          ]
        }
        """.utf8)
        let provider = try AntigravityUsageParser.summary(from: data, plan: "Pro", now: .now)
        #expect(provider.lines.map(\.label) == ["Gemini 5h", "Claude 5h", "Gemini Weekly", "Claude Weekly"])
        #expect(abs((provider.lines[0].remainingPercent ?? 0) - 0.3) < 0.0001)
        #expect(provider.lines[0].resetsAt != nil)
        #expect(provider.lines[0].periodDurationMs == 18_000_000.0)
        #expect(provider.lines[2].periodDurationMs == 604_800_000.0)
        #expect(abs((provider.lines[3].remainingPercent ?? 0) - 0.886) < 0.0001)
        #expect(abs((provider.displayRemainingPercent ?? 0) - 0.3) < 0.0001)
        #expect(abs((provider.lowestRemainingPercent ?? 0) - 0.3) < 0.0001)
    }

    @Test func summaryUsesWindowMinutesWhenWindowLabelMissing() throws {
        let data = Data("""
        {"groups":[{"displayName":"Gemini Models","buckets":[
            {"bucketId":"x","windowMinutes":300,"remainingFraction":0.5},
            {"bucketId":"y","windowMinutes":10080,"remainingFraction":0.4}
        ]}]}
        """.utf8)
        let provider = try AntigravityUsageParser.summary(from: data, plan: nil, now: .now)
        #expect(provider.lines.map(\.label) == ["Gemini 5h", "Gemini Weekly"])
        #expect(provider.lowestRemainingPercent == 0.4)
    }

    @Test func summarySkipsUnknownGroupsAndMissingBuckets() throws {
        let data = Data("""
        {"groups":[
            {"displayName":"Internal Telemetry","buckets":[
                {"window":"5h","remainingFraction":0.5}
            ]},
            {"displayName":"Gemini Models","buckets":[
                {"window":"5h"},
                {"displayName":"Weekly Limit Remaining","remainingFraction":0.9}
            ]}
        ]}
        """.utf8)
        let provider = try AntigravityUsageParser.summary(from: data, plan: nil, now: .now)
        #expect(provider.lines.map(\.label) == ["Gemini Weekly"])
        #expect(abs((provider.lowestRemainingPercent ?? 0) - 0.9) < 0.0001)
    }

    @Test func summaryIsUnavailableWhenAllBucketsMissing() {
        let data = Data(#"{"groups":[{"displayName":"Gemini Models","buckets":[{"window":"5h"}]}]}"#.utf8)
        #expect(throws: AntigravityError.quotaUnavailable) {
            try AntigravityUsageParser.summary(from: data, plan: nil, now: .now)
        }
    }

    @Test func summaryRejectsOutOfRangeFraction() {
        let data = Data("""
        {"groups":[{"displayName":"Gemini Models","buckets":[
            {"window":"5h","remainingFraction":1.2}
        ]}]}
        """.utf8)
        #expect(throws: AntigravityError.invalidResponse) {
            try AntigravityUsageParser.summary(from: data, plan: nil, now: .now)
        }
    }

    @Test func fetchPrefersQuotaSummaryAndFallsBackToCatalog() async throws {
        let summary = Data("""
        {"groups":[{"displayName":"Gemini Models","buckets":[
            {"window":"5h","remainingFraction":0.6}
        ]}]}
        """.utf8)
        let transport = AntigravityTestTransport([
            (200, #"{"cloudaicompanionProject":"project"}"#),
            (200, String(data: summary, encoding: .utf8)!),
        ])
        let provider = try await AntigravityDirectClient(transport: transport).fetch(accessToken: "access")
        #expect(provider.lines.first?.label == "Gemini 5h")
        #expect(await transport.requests.count == 2)
        let paths = await transport.requests.map { $0.url?.path ?? "" }
        #expect(paths.contains(where: { $0.contains("retrieveUserQuotaSummary") }))

        let catalog = Data(#"{"models":{"gemini-pro":{"quotaInfo":{"remainingFraction":0.1}}}}"#.utf8)
        let fallbackTransport = AntigravityTestTransport([
            (200, #"{"cloudaicompanionProject":"project"}"#),
            (404, "{}"),
            (200, String(data: catalog, encoding: .utf8)!),
        ])
        let fallbackProvider = try await AntigravityDirectClient(transport: fallbackTransport).fetch(accessToken: "access")
        #expect(fallbackProvider.lines.first?.label == "Gemini")
        #expect(abs((fallbackProvider.lines.first?.remainingPercent ?? 0) - 0.1) < 0.0001)
        #expect(await fallbackTransport.requests.count == 3)
    }

    @Test func rejectsOutOfRangeQuota() {
        #expect(throws: AntigravityError.invalidResponse) {
            try AntigravityUsageParser.provider(from: Data(#"{"models":{"gemini-pro":{"quotaInfo":{"remainingFraction":1.2}}}}"#.utf8), plan: nil, now: .now)
        }
    }

    @Test func authorizationUsesPKCEAndOfflineAccess() throws {
        let flow = try AntigravityOAuthRequest()
        let query = URLComponents(url: flow.authorizationURL(port: 51121), resolvingAgainstBaseURL: false)!.queryItems!
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value!) })
        #expect(values["code_challenge_method"] == "S256")
        #expect(values["code_challenge"]?.count == 43)
        #expect(values["code_challenge"] != flow.verifier)
        #expect(values["state"] == flow.state)
        #expect(values["access_type"] == "offline")
        #expect(values["redirect_uri"] == "http://127.0.0.1:51121/oauth-callback")
        #expect(try flow.callbackCode(target: "/oauth-callback?state=\(flow.state)&code=test-code") == "test-code")
        #expect(throws: AntigravityError.invalidCallback) {
            try flow.callbackCode(target: "/oauth-callback?state=wrong&code=test-code")
        }
        #expect(throws: AntigravityError.invalidCallback) {
            try flow.callbackCode(target: "/wrong?state=\(flow.state)&code=test-code")
        }
        #expect(throws: AntigravityError.authorizationDenied) {
            try flow.callbackCode(target: "/oauth-callback?state=\(flow.state)&error=access_denied")
        }
    }

    @Test func buildConfigLoadsNonEmptyCredentials() {
        #expect(!AntigravityBuildConfig.clientID.isEmpty)
        #expect(!AntigravityBuildConfig.clientSecret.isEmpty)
        #expect(AntigravityBuildConfig.isConfigured)
        #expect(AntigravityOAuthRequest.clientID == AntigravityBuildConfig.clientID)
        #expect(AntigravityOAuthRequest.clientSecret == AntigravityBuildConfig.clientSecret)
    }
}

private actor AntigravityTestTransport: BoundedHTTPTransporting {
    var replies: [(Int, String)]
    var requests: [URLRequest] = []
    init(_ replies: [(Int, String)]) { self.replies = replies }
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let reply = replies.removeFirst()
        return (Data(reply.1.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!)
    }
}

extension AntigravityTests {
    @Test func usesReturnedProjectAndDoesNotSendRefreshTokenToQuotaEndpoint() async throws {
        let transport = AntigravityTestTransport([
            (200, #"{"cloudaicompanionProject":"real-project","paidTier":{"name":"Ultra"}}"#),
            (404, "{}"),
            (200, #"{"models":{"gemini-pro":{"quotaInfo":{"remainingFraction":0.6}}}}"#)
        ])
        let provider = try await AntigravityDirectClient(transport: transport).fetch(accessToken: "access")
        #expect(provider.plan == "Ultra")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.url?.host == "daily-cloudcode-pa.googleapis.com" })
        let body = try JSONSerialization.jsonObject(with: requests[2].httpBody!) as! [String: String]
        #expect(body["project"] == "real-project")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer access")
    }

    @Test func missingProjectStopsQuotaRequest() async {
        let transport = AntigravityTestTransport([(200, "{}")])
        await #expect(throws: AntigravityError.projectUnavailable) {
            try await AntigravityDirectClient(transport: transport).fetch(accessToken: "access")
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func tokenRefreshPreservesRefreshTokenAndEncodesForm() async throws {
        let transport = AntigravityTestTransport([(200, #"{"access_token":"new-access","expires_in":3600}"#)])
        let old = AntigravityCredential(accessToken: "old", refreshToken: "a+b&c=d", expiresAt: .distantPast)
        let new = try await AntigravityDirectClient(transport: transport).refresh(old)
        #expect(new.accessToken == "new-access")
        #expect(new.refreshToken == old.refreshToken)
        let request = await transport.requests[0]
        #expect(String(data: request.httpBody!, encoding: .utf8)!.contains("refresh_token=a%2Bb%26c%3Dd"))
    }

    @Test @MainActor func missingCredentialDoesNotFetch() async {
        let transport = AntigravityTestTransport([])
        let connection = AntigravityConnection(credentials: AntigravityTestCredentials(), client: AntigravityDirectClient(transport: transport))
        await connection.refresh()
        #expect(connection.provider == nil)
        #expect(connection.statusKey == "antigravity.disconnected")
        #expect(await transport.requests.isEmpty)
    }

    @Test @MainActor func failedRefreshRemovesStaleQuotaAndDisconnectDeletesCredential() async throws {
        let credentials = AntigravityTestCredentials()
        credentials.value = AntigravityCredential(accessToken: "access", refreshToken: "refresh", expiresAt: .distantFuture)
        let transport = AntigravityTestTransport([
            (200, #"{"cloudaicompanionProject":"project"}"#),
            (404, "{}"),
            (200, #"{"models":{"gemini-pro":{"quotaInfo":{"remainingFraction":0.6}}}}"#),
            (200, #"{"cloudaicompanionProject":"project"}"#),
            (404, "{}"),
            (403, "{}")
        ])
        let connection = AntigravityConnection(credentials: credentials, client: AntigravityDirectClient(transport: transport))
        await connection.refresh()
        #expect(connection.provider != nil)
        await connection.refresh()
        #expect(connection.provider == nil)
        #expect(connection.statusKey == "antigravity.forbidden")
        connection.disconnect()
        #expect(credentials.value == nil)
        #expect(connection.statusKey == "antigravity.disconnected")
    }
}

@MainActor private final class AntigravityTestCredentials: AntigravityCredentialStoring {
    var value: AntigravityCredential?
    func load() throws -> AntigravityCredential? { value }
    func save(_ credential: AntigravityCredential) throws { value = credential }
    func delete() throws { value = nil }
}

extension AntigravityTests {
    @Test @MainActor func loopbackCallbackRejectsWrongStateThenAcceptsValidCode() async throws {
        let flow = try AntigravityOAuthRequest()
        let oauth = AntigravityOAuth()
        var browserTask: Task<Void, Error>?
        let callback = try await oauth.authorize(flow) { url in
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            let redirect = query.first { $0.name == "redirect_uri" }!.value!
            browserTask = Task {
                let session = URLSession(configuration: .ephemeral)
                defer { session.invalidateAndCancel() }
                let (_, rejected) = try await session.data(from: URL(string: redirect + "?state=wrong&code=wrong")!)
                #expect((rejected as? HTTPURLResponse)?.statusCode == 400)
                let (_, accepted) = try await session.data(from: URL(string: redirect + "?state=\(flow.state)&code=valid")!)
                #expect((accepted as? HTTPURLResponse)?.statusCode == 200)
            }
            return true
        }
        try await browserTask?.value
        #expect(callback.code == "valid")
        #expect(callback.redirectURI.hasPrefix("http://127.0.0.1:"))
    }

    @Test @MainActor func browserFailureEndsAuthorization() async throws {
        let flow = try AntigravityOAuthRequest()
        await #expect(throws: AntigravityError.browserUnavailable) {
            try await AntigravityOAuth().authorize(flow, open: { _ in false })
        }
    }

    @Test @MainActor func disconnectWhileRefreshingCannotRestoreCredentialsOrQuota() async throws {
        let credentials = AntigravityTestCredentials()
        credentials.value = AntigravityCredential(accessToken: "old", refreshToken: "refresh", expiresAt: .distantPast)
        let transport = AntigravityDelayedTransport()
        let connection = AntigravityConnection(credentials: credentials, client: AntigravityDirectClient(transport: transport))
        let task = Task { await connection.refresh() }
        await transport.waitUntilRequested()
        connection.disconnect()
        await transport.complete()
        await task.value
        #expect(credentials.value == nil)
        #expect(connection.provider == nil)
        #expect(connection.statusKey == "antigravity.disconnected")
    }
}

private actor AntigravityDelayedTransport: BoundedHTTPTransporting {
    var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    var started: CheckedContinuation<Void, Never>?
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation {
            pending = $0
            started?.resume()
            started = nil
        }
    }
    func complete() {
        pending!.resume(returning: (
            Data(#"{"access_token":"new","refresh_token":"rotated","expires_in":3600}"#.utf8),
            HTTPURLResponse(url: URL(string: "https://oauth2.googleapis.com/token")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        ))
        pending = nil
    }
}
