import Foundation

struct CodexDirectSnapshot: Sendable {
    let provider: ProviderUsage
    let resetCredits: CodexResetCredits?
}

struct CodexDirectClient: Sendable {
    private let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    private let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
    private let maximumPayloadSize = 1_048_576

    func fetch() async throws -> CodexDirectSnapshot {
        let auth = try loadAuth()
        async let usageRequest = request(usageURL, auth: auth)
        async let creditsRequest = try? request(resetCreditsURL, auth: auth)

        let usageData = try await usageRequest
        let creditsData = await creditsRequest
        let usage = try JSONDecoder().decode(UsageEnvelope.self, from: usageData)
        let now = Date.now

        let windows = [usage.rateLimit?.primaryWindow, usage.rateLimit?.secondaryWindow]
            .compactMap { $0 }
            .compactMap { usageLine(from: $0, now: now) }
        guard !windows.isEmpty else { throw DirectError.malformedUsage }

        let uniqueLines = windows.reduce(into: [String: UsageLine]()) { result, line in
            result[line.label] = line
        }.values.sorted { $0.label < $1.label }

        let provider = ProviderUsage(
            providerId: "codex",
            displayName: "Codex",
            plan: usage.planType?.uppercased(),
            lines: uniqueLines,
            fetchedAt: now
        )

        let endpointCredits = creditsData.flatMap { try? JSONDecoder().decode(CreditEnvelope.self, from: $0) }
        let creditPayload = endpointCredits ?? usage.rateLimitResetCredits
        let resetCredits = creditPayload.flatMap { payload -> CodexResetCredits? in
            guard let count = payload.availableCount else { return nil }
            let expirations = payload.credits
                .filter { $0.redeemedAt == nil }
                .compactMap { parseISO8601($0.expiresAt) }
                .filter { $0 > now }
                .sorted()
            return CodexResetCredits(availableCount: count, expirations: expirations, fetchedAt: now)
        }

        return CodexDirectSnapshot(provider: provider, resetCredits: resetCredits)
    }

    private func usageLine(from window: DirectWindow, now: Date) -> UsageLine? {
        guard let usedPercent = window.usedPercent else { return nil }
        let duration = window.limitWindowSeconds
        let resetAt = window.resetAt.map(Date.init(timeIntervalSince1970:))
        let isShortWindow: Bool
        if let duration {
            isShortWindow = duration <= 12 * 60 * 60
        } else if let resetAt {
            isShortWindow = resetAt.timeIntervalSince(now) <= 12 * 60 * 60
        } else {
            return nil
        }

        return UsageLine(
            type: "progress",
            label: isShortWindow ? "Session" : "Weekly",
            used: min(max(usedPercent, 0), 100),
            limit: 100,
            resetsAt: resetAt,
            periodDurationMs: duration.map { $0 * 1_000 },
            value: nil,
            subtitle: nil
        )
    }

    private func loadAuth() throws -> DirectAuth {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let url = home.appendingPathComponent("auth.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 262_144 else {
            throw DirectError.authUnavailable
        }
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(AuthEnvelope.self, from: data)
        let tokens = envelope.tokens ?? envelope.rootTokens
        guard let accessToken = tokens.accessToken, !accessToken.isEmpty else {
            throw DirectError.authUnavailable
        }
        let accountId = tokens.accountId ?? accountId(from: accessToken)
        return DirectAuth(accessToken: accessToken, accountId: accountId)
    }

    private func request(_ url: URL, auth: DirectAuth) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("CODEX", forHTTPHeaderField: "OAI-Product-Sku")
        if let accountId = auth.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DirectError.requestFailed
        }
        guard data.count <= maximumPayloadSize else { throw DirectError.payloadTooLarge }
        return data
    }

    private func accountId(from token: String) -> String? {
        let segments = token.split(separator: ".")
        guard segments.count > 1 else { return nil }
        var payload = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["https://api.openai.com/auth.chatgpt_account_id"] as? String
            ?? json["chatgpt_account_id"] as? String
    }

    private func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private extension CodexDirectClient {
    enum DirectError: Error {
        case authUnavailable
        case requestFailed
        case payloadTooLarge
        case malformedUsage
    }

    struct DirectAuth: Sendable {
        let accessToken: String
        let accountId: String?
    }

    struct AuthEnvelope: Decodable {
        struct Tokens: Decodable {
            let accessToken: String?
            let accountId: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
            }
        }

        let tokens: Tokens?
        let accessToken: String?
        let accountId: String?

        var rootTokens: Tokens { Tokens(accessToken: accessToken, accountId: accountId) }

        enum CodingKeys: String, CodingKey {
            case tokens
            case accessToken = "access_token"
            case accountId = "account_id"
        }
    }

    struct UsageEnvelope: Decodable {
        let planType: String?
        let rateLimit: RateLimit?
        let rateLimitResetCredits: CreditEnvelope?

        enum CodingKeys: String, CodingKey {
            case planType = "plan_type"
            case rateLimit = "rate_limit"
            case rateLimitResetCredits = "rate_limit_reset_credits"
        }
    }

    struct RateLimit: Decodable {
        let primaryWindow: DirectWindow?
        let secondaryWindow: DirectWindow?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    struct DirectWindow: Decodable {
        let usedPercent: Double?
        let resetAt: Double?
        let limitWindowSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }

    struct CreditEnvelope: Decodable {
        let availableCount: Int?
        let credits: [Credit]

        enum CodingKeys: String, CodingKey {
            case availableCount = "available_count"
            case credits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            availableCount = try container.decodeIfPresent(Int.self, forKey: .availableCount)
            credits = try container.decodeIfPresent([Credit].self, forKey: .credits) ?? []
        }
    }

    struct Credit: Decodable {
        let expiresAt: String?
        let redeemedAt: String?

        enum CodingKeys: String, CodingKey {
            case expiresAt = "expires_at"
            case redeemedAt = "redeemed_at"
        }
    }
}
