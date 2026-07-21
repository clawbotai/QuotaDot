import Foundation
import OSLog

actor KimiDirectClient {
    private let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    private let tokenURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    private let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    private let maximumPayloadSize = 1_048_576
    private let logger = Logger(subsystem: "com.quotadot.app", category: "kimi-auth")

    func fetch() async throws -> ProviderUsage {
        var credential = try loadCredential()
        if KimiCredentialPolicy.shouldRefresh(
            expiresAtSeconds: credential.expiresAt,
            expiresInSeconds: credential.expiresIn,
            now: .now
        ) {
            do {
                credential = try await refreshCredential(invalidAccessToken: nil)
            } catch {
                guard !KimiCredentialPolicy.isExpired(expiresAtSeconds: credential.expiresAt, now: .now) else {
                    throw error
                }
                logger.warning("Kimi token refresh was deferred; using the still-valid access token")
            }
        }

        do {
            return try await fetchUsage(accessToken: credential.accessToken)
        } catch KimiError.requestFailed(statusCode: 401) {
            let latest = try loadCredential()
            if latest.accessToken != credential.accessToken {
                return try await fetchUsage(accessToken: latest.accessToken)
            }

            let refreshed = try await refreshCredential(invalidAccessToken: credential.accessToken)
            return try await fetchUsage(accessToken: refreshed.accessToken)
        }
    }

    private func fetchUsage(accessToken: String) async throws -> ProviderUsage {
        var request = URLRequest(url: usageURL)
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard data.count <= maximumPayloadSize else { throw KimiError.payloadTooLarge }
        guard let http = response as? HTTPURLResponse else {
            throw KimiError.invalidResponse
        }
        guard http.statusCode == 200 else {
            throw KimiError.requestFailed(statusCode: http.statusCode)
        }
        return try KimiUsageParser.provider(from: data, now: .now)
    }

    private func refreshCredential(invalidAccessToken: String?) async throws -> Credential {
        let home = kimiHomeDirectory()
        let lockURL = try await acquireRefreshLock(home: home)
        defer { try? FileManager.default.removeItem(at: lockURL) }

        let current = try loadCredential(home: home)
        if let invalidAccessToken, current.accessToken != invalidAccessToken {
            return current
        }
        guard let refreshToken = current.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            throw KimiError.authUnavailable
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncoded([
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        guard data.count <= maximumPayloadSize else { throw KimiError.payloadTooLarge }
        guard let http = response as? HTTPURLResponse else { throw KimiError.invalidResponse }
        guard http.statusCode == 200 else {
            throw KimiError.refreshFailed(statusCode: http.statusCode)
        }

        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        let accessToken = payload.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextRefreshToken = payload.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty, !nextRefreshToken.isEmpty, payload.expiresIn > 0 else {
            throw KimiError.malformedCredential
        }

        let refreshed = Credential(
            accessToken: accessToken,
            refreshToken: nextRefreshToken,
            expiresAt: floor(Date.now.timeIntervalSince1970) + payload.expiresIn,
            scope: payload.scope ?? current.scope,
            tokenType: payload.tokenType ?? current.tokenType,
            expiresIn: payload.expiresIn
        )
        try saveCredential(refreshed, home: home)
        logger.info("Kimi OAuth token refreshed and persisted")
        return refreshed
    }

    private func loadCredential(home: URL? = nil) throws -> Credential {
        let home = home ?? kimiHomeDirectory()
        let url = home.appendingPathComponent("credentials/kimi-code.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 262_144 else {
            throw KimiError.authUnavailable
        }
        let data = try Data(contentsOf: url)
        let credential = try JSONDecoder().decode(Credential.self, from: data)
        guard !credential.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KimiError.authUnavailable
        }
        return credential
    }

    private func saveCredential(_ credential: Credential, home: URL) throws {
        let directory = home.appendingPathComponent("credentials", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = directory.appendingPathComponent("kimi-code.json")
        let data = try JSONEncoder().encode(credential)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func acquireRefreshLock(home: URL) async throws -> URL {
        let directory = home.appendingPathComponent("oauth", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let target = directory.appendingPathComponent("kimi-code")
        if !FileManager.default.fileExists(atPath: target.path) {
            guard FileManager.default.createFile(
                atPath: target.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw KimiError.lockUnavailable
            }
        }

        let lockURL = directory.appendingPathComponent("kimi-code.lock", isDirectory: true)
        for _ in 0..<40 {
            do {
                try FileManager.default.createDirectory(
                    at: lockURL,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                return lockURL
            } catch {
                guard FileManager.default.fileExists(atPath: lockURL.path) else { throw error }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        throw KimiError.lockUnavailable
    }

    private func kimiHomeDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        return environment["KIMI_CODE_HOME"].flatMap { value in
            value.isEmpty ? nil : URL(fileURLWithPath: value, isDirectory: true)
        } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code", isDirectory: true)
    }

    private func formEncoded(_ parameters: [String: String]) -> Data? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return parameters
            .sorted(by: { $0.key < $1.key })
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
            .data(using: .utf8)
    }
}

enum KimiCredentialPolicy {
    static func shouldRefresh(expiresAtSeconds: Double?, expiresInSeconds: Double?, now: Date) -> Bool {
        guard let expiresAtSeconds else { return false }
        let lifetime = max(expiresInSeconds ?? 600, 0)
        let leeway = min(300, lifetime / 2)
        return expiresAtSeconds - now.timeIntervalSince1970 <= leeway
    }

    static func isExpired(expiresAtSeconds: Double?, now: Date) -> Bool {
        guard let expiresAtSeconds else { return false }
        return expiresAtSeconds <= now.timeIntervalSince1970
    }
}

enum KimiUsageParser {
    static func provider(from data: Data, now: Date) throws -> ProviderUsage {
        let payload = try JSONDecoder().decode(UsageEnvelope.self, from: data)
        var lines: [UsageLine] = []

        if let session = payload.limits.compactMap(sessionLine).min(by: {
            ($0.periodDurationMs ?? .greatestFiniteMagnitude) < ($1.periodDurationMs ?? .greatestFiniteMagnitude)
        }) {
            lines.append(session)
        }
        if let weekly = quotaLine(label: "Weekly", detail: payload.usage, durationMs: 7 * 24 * 60 * 60 * 1_000) {
            lines.append(weekly)
        }

        guard !lines.isEmpty else { throw KimiError.malformedUsage }
        return ProviderUsage(
            providerId: "kimi",
            displayName: "Kimi",
            plan: "Kimi Code",
            lines: lines,
            fetchedAt: now
        )
    }

    private static func sessionLine(_ item: LimitEnvelope) -> UsageLine? {
        guard let detail = item.detail,
              let durationMs = item.window?.durationMilliseconds,
              durationMs <= 12 * 60 * 60 * 1_000 else { return nil }
        return quotaLine(label: "Session", detail: detail, durationMs: durationMs)
    }

    private static func quotaLine(label: String, detail: QuotaDetail?, durationMs: Double) -> UsageLine? {
        guard let detail,
              let limit = detail.limit?.value,
              limit > 0 else { return nil }
        let remaining = min(max(detail.remaining?.value ?? limit, 0), limit)
        return UsageLine(
            type: "progress",
            label: label,
            used: limit - remaining,
            limit: limit,
            resetsAt: parseISO8601(detail.resetTime),
            periodDurationMs: durationMs,
            value: nil,
            subtitle: nil
        )
    }

    private static func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private extension KimiDirectClient {
    struct Credential: Codable {
        let accessToken: String
        let refreshToken: String?
        let expiresAt: Double?
        let scope: String?
        let tokenType: String?
        let expiresIn: Double?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresAt = "expires_at"
            case scope
            case tokenType = "token_type"
            case expiresIn = "expires_in"
        }
    }

    struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let scope: String?
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case tokenType = "token_type"
        }
    }
}

private extension KimiUsageParser {
    struct UsageEnvelope: Decodable {
        let usage: QuotaDetail?
        let limits: [LimitEnvelope]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usage = try container.decodeIfPresent(QuotaDetail.self, forKey: .usage)
            limits = try container.decodeIfPresent([LimitEnvelope].self, forKey: .limits) ?? []
        }

        enum CodingKeys: String, CodingKey {
            case usage
            case limits
        }
    }

    struct LimitEnvelope: Decodable {
        let window: QuotaWindow?
        let detail: QuotaDetail?
    }

    struct QuotaWindow: Decodable {
        let duration: FlexibleNumber?
        let timeUnit: String?

        var durationMilliseconds: Double? {
            guard let duration = duration?.value, duration > 0 else { return nil }
            let seconds: Double
            switch timeUnit?.uppercased() {
            case let unit? where unit.contains("MINUTE"):
                seconds = duration * 60
            case let unit? where unit.contains("HOUR"):
                seconds = duration * 60 * 60
            case let unit? where unit.contains("DAY"):
                seconds = duration * 24 * 60 * 60
            default:
                seconds = duration
            }
            return seconds * 1_000
        }
    }

    struct QuotaDetail: Decodable {
        let limit: FlexibleNumber?
        let remaining: FlexibleNumber?
        let resetTime: String?
    }

    struct FlexibleNumber: Decodable {
        let value: Double

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self) {
                value = number
            } else if let text = try? container.decode(String.self), let number = Double(text) {
                value = number
            } else {
                throw DecodingError.typeMismatch(
                    Double.self,
                    DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a numeric value")
                )
            }
        }
    }
}

private enum KimiError: Error {
    case authUnavailable
    case invalidResponse
    case requestFailed(statusCode: Int)
    case refreshFailed(statusCode: Int)
    case malformedCredential
    case lockUnavailable
    case payloadTooLarge
    case malformedUsage
}
