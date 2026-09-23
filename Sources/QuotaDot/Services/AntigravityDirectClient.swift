import Foundation

enum AntigravityError: Error, Equatable {
    case invalidResponse, quotaUnavailable, projectUnavailable, unauthorized
    case http(Int), invalidCallback, authorizationDenied, authorizationTimedOut, browserUnavailable
    case configurationMissing
}

struct AntigravityCredential: Codable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
}

struct AntigravityDirectClient: Sendable {
    var transport: any BoundedHTTPTransporting = URLSessionBoundedTransport(statusError: { _ in nil })

    func exchange(code: String, verifier: String, redirectURI: String) async throws -> AntigravityCredential {
        try await token(parameters: ["code": code, "code_verifier": verifier,
                                     "redirect_uri": redirectURI, "grant_type": "authorization_code"], previous: nil)
    }

    func refresh(_ credential: AntigravityCredential) async throws -> AntigravityCredential {
        try await token(parameters: ["refresh_token": credential.refreshToken, "grant_type": "refresh_token"], previous: credential)
    }

    private func token(parameters: [String: String], previous: AntigravityCredential?) async throws -> AntigravityCredential {
        var values = parameters
        values["client_id"] = AntigravityOAuthRequest.clientID
        values["client_secret"] = AntigravityOAuthRequest.clientSecret
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        let (data, response) = try await transport.data(for: request, maximumBytes: 1_048_576)
        if response.statusCode == 400,
           let error = try? JSONDecoder().decode(OAuthFailure.self, from: data), error.error == "invalid_grant" {
            throw AntigravityError.unauthorized
        }
        try check(response)
        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard !payload.access_token.isEmpty, payload.expires_in > 0,
              let refreshToken = payload.refresh_token ?? previous?.refreshToken, !refreshToken.isEmpty else {
            throw AntigravityError.invalidResponse
        }
        return AntigravityCredential(accessToken: payload.access_token, refreshToken: refreshToken,
                                     expiresAt: .now.addingTimeInterval(payload.expires_in))
    }

    func fetch(accessToken: String) async throws -> ProviderUsage {
        let assistData = try await post("loadCodeAssist", token: accessToken,
                                       body: ["metadata": ["ideType": "ANTIGRAVITY"]])
        let assist = try JSONDecoder().decode(AssistResponse.self, from: assistData)
        guard let project = assist.cloudaicompanionProject, !project.isEmpty else {
            throw AntigravityError.projectUnavailable
        }
        let plan = assist.paidTier?.name ?? assist.currentTier?.name
        // The official Antigravity /usage surface reads from
        // retrieveUserQuotaSummary so the buckets shown here match the IDE.
        // The summary RPC may not be enabled for every project, so fall back
        // to the per-model catalog when it is missing or empty.
        if let summary = try? await post("retrieveUserQuotaSummary", token: accessToken,
                                        body: ["project": project]),
           let provider = try? AntigravityUsageParser.summary(from: summary, plan: plan, now: .now),
           !provider.lines.isEmpty {
            return provider
        }
        let catalog = try await post("fetchAvailableModels", token: accessToken,
                                     body: ["project": project])
        return try AntigravityUsageParser.provider(from: catalog,
            plan: plan, now: .now)
    }

    private func post(_ method: String, token: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("antigravity/hub/2.12.2 (aidev_client; os_type=darwin; arch=arm64; cl=975423596)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await transport.data(for: request, maximumBytes: 1_048_576)
        try check(response)
        return data
    }

    private func check(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 { throw AntigravityError.unauthorized }
        guard (200..<300).contains(response.statusCode) else { throw AntigravityError.http(response.statusCode) }
    }

    private struct OAuthFailure: Decodable { let error: String }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }
    private struct AssistResponse: Decodable {
        let cloudaicompanionProject: String?
        let paidTier: Tier?
        let currentTier: Tier?
        struct Tier: Decodable { let name: String? }
    }
}

enum AntigravityUsageParser {
    /// Parses the user-level quota summary returned by
    /// `v1internal:retrieveUserQuotaSummary`. This is the same endpoint the
    /// Antigravity IDE renders under **/usage**, so the buckets shown here
    /// match the IDE exactly instead of being inferred from model names.
    static func summary(from data: Data, plan: String?, now: Date) throws -> ProviderUsage {
        let payload = try JSONDecoder().decode(Summary.self, from: data)
        var lines: [UsageLine] = []
        for group in payload.groups ?? [] {
            let groupName = (group.displayName ?? group.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let groupLabel = AntigravityUsageParser.groupLabel(for: groupName) else { continue }
            for bucket in group.buckets {
                guard let fraction = bucket.remainingFraction else { continue }
                guard fraction.isFinite, (0...1).contains(fraction) else { throw AntigravityError.invalidResponse }
                guard let windowLabel = AntigravityUsageParser.windowLabel(for: bucket) else { continue }
                let reset = bucket.resetTime.flatMap(AntigravityUsageParser.parseReset)
                if bucket.resetTime != nil && reset == nil { throw AntigravityError.invalidResponse }
                let periodMs = bucket.windowMinutes ?? AntigravityUsageParser.defaultPeriodMs(for: windowLabel)
                let line = UsageLine(type: "progress", label: "\(groupLabel) \(windowLabel)",
                                     used: 1 - fraction, limit: 1,
                                     resetsAt: reset, periodDurationMs: periodMs,
                                     value: nil, subtitle: nil)
                if let existing = lines.firstIndex(where: { $0.label == line.label }),
                   (lines[existing].remainingPercent ?? 0) <= fraction { continue }
                lines.append(line)
            }
        }
        guard !lines.isEmpty else { throw AntigravityError.quotaUnavailable }
        let ordered = AntigravityUsageParser.orderedBuckets(lines)
        return ProviderUsage(providerId: "antigravity", displayName: "Antigravity",
                             plan: plan, lines: ordered, fetchedAt: now)
    }

    /// Fallback parser used when `retrieveUserQuotaSummary` is missing or
    /// rejects the project. Heuristically groups the per-model
    /// `fetchAvailableModels` catalog into Gemini / Claude buckets.
    static func provider(from data: Data, plan: String?, now: Date) throws -> ProviderUsage {
        let payload = try JSONDecoder().decode(Envelope.self, from: data)
        var pools: [String: UsageLine] = [:]
        for (model, info) in payload.models.sorted(by: { $0.key < $1.key }) {
            let key = model.lowercased()
            guard let label = AntigravityUsageParser.legacyBucketLabel(for: key) else { continue }
            guard let quota = info.quotaInfo, let fraction = quota.remainingFraction else { continue }
            guard fraction.isFinite, (0...1).contains(fraction) else { throw AntigravityError.invalidResponse }
            let reset: Date?
            if let value = quota.resetTime {
                reset = AntigravityUsageParser.parseReset(value)
                guard reset != nil else { throw AntigravityError.invalidResponse }
            } else { reset = nil }
            if let existing = pools[label]?.remainingPercent, existing <= fraction { continue }
            pools[label] = UsageLine(type: "progress", label: label, used: 1 - fraction, limit: 1,
                                     resetsAt: reset, periodDurationMs: nil,
                                     value: nil, subtitle: nil)
        }
        let lines = ["Gemini", "Claude"].compactMap { pools[$0] }
        guard !lines.isEmpty else { throw AntigravityError.quotaUnavailable }
        return ProviderUsage(providerId: "antigravity", displayName: "Antigravity",
                             plan: plan, lines: lines, fetchedAt: now)
    }

    private static func groupLabel(for name: String) -> String? {
        let lower = name.lowercased()
        if lower.contains("gemini") { return "Gemini" }
        if lower.contains("claude") || lower.contains("gpt") { return "Claude" }
        return nil
    }

    private static func windowLabel(for bucket: Summary.Bucket) -> String? {
        let candidates = [bucket.window, bucket.bucketId, bucket.displayName].compactMap { $0?.lowercased() }
        for raw in candidates {
            if raw.contains("5h") || raw.contains("five hour") || raw.contains("fivehour") { return "5h" }
            if raw.contains("weekly") || raw.contains("week") || raw.contains("seven day") { return "Weekly" }
        }
        if let minutes = bucket.windowMinutes {
            switch minutes {
            case 0..<360: return "5h"
            case 360...(24 * 60 * 7): return "Weekly"
            default: return nil
            }
        }
        return nil
    }

    private static func defaultPeriodMs(for window: String) -> Double {
        switch window {
        case "5h": return 5 * 60 * 60 * 1000
        case "Weekly": return 7 * 24 * 60 * 60 * 1000
        default: return 0
        }
    }

    private static func legacyBucketLabel(for key: String) -> String? {
        if key.contains("claude") || key.contains("sonnet") || key.contains("opus") { return "Claude" }
        if key.contains("gemini") { return "Gemini" }
        return nil
    }

    /// Buckets appear as 5h/weekly for each group. Order them so the 5h
    /// limit for every group leads, followed by each group's weekly limit,
    /// matching the layout the Antigravity IDE uses.
    private static func orderedBuckets(_ lines: [UsageLine]) -> [UsageLine] {
        let fiveh = lines.filter { $0.label.hasSuffix(" 5h") }
        let weekly = lines.filter { $0.label.hasSuffix(" Weekly") }
        var combined = fiveh
        combined.append(contentsOf: weekly)
        return combined
    }

    private static func parseReset(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return basic.date(from: string)
    }

    private struct Summary: Decodable {
        let groups: [Group]?
        struct Group: Decodable {
            let displayName: String?
            let description: String?
            let buckets: [Bucket]
        }
        struct Bucket: Decodable {
            let bucketId: String?
            let displayName: String?
            let window: String?
            let windowMinutes: Double?
            let resetTime: String?
            let remainingFraction: Double?
        }
    }

    private struct Envelope: Decodable {
        let models: [String: Model]
        struct Model: Decodable { let quotaInfo: Quota? }
        struct Quota: Decodable { let remainingFraction: Double?; let resetTime: String? }
    }
}
