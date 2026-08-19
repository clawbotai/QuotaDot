import Foundation

protocol GLMUsageClient: Sendable {
    func fetch(apiKey: String) async throws -> ProviderUsage
}

enum GLMClientError: Error, Sendable, Equatable {
    case keyMissing
    case invalidLocalKey
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

    static func httpStatus(_ statusCode: Int) -> Self? {
        switch statusCode {
        case 200: nil
        case 401, 403: .unauthorized
        case 429: .rateLimited
        case 400..<500: .clientRejected
        case 500..<600: .serverUnavailable
        default: .unexpectedHTTPStatus
        }
    }
}

struct GLMDirectClient: GLMUsageClient {
    static let cnHost = "open.bigmodel.cn"
    static let globalHost = "api.z.ai"
    private static let quotaPath = "/api/monitor/usage/quota/limit"
    private static let sessionWindowMs: Double = 5 * 3_600 * 1_000
    private static let weeklyWindowMs: Double = 7 * 24 * 3_600 * 1_000

    private let maximumPayloadSize = 1_048_576
    private let transport: any BoundedHTTPTransporting
    private let now: @Sendable () -> Date
    private let lastSuccessfulHost = HostPreference()

    init(
        transport: (any BoundedHTTPTransporting)? = nil,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.transport = transport ?? URLSessionBoundedTransport(statusError: { GLMClientError.httpStatus($0) })
        self.now = now
    }

    func fetch(apiKey: String) async throws -> ProviderUsage {
        let key = try Self.validatedAPIKey(apiKey)

        // Prefer the mainland endpoint; remember whichever host last answered
        // so later refreshes skip a known-broken region first.
        let primary = lastSuccessfulHost.value ?? Self.cnHost
        let secondary = primary == Self.cnHost ? Self.globalHost : Self.cnHost
        var lastError = GLMClientError.networkFailure
        for (index, host) in [primary, secondary].enumerated() {
            do {
                let provider = try await fetchOnce(host: host, apiKey: key)
                lastSuccessfulHost.value = host
                return provider
            } catch let error as GLMClientError {
                lastError = error
                guard index == 0 else { throw error }
                switch error {
                case .networkFailure, .serverUnavailable, .unauthorized:
                    continue
                default:
                    throw error
                }
            }
        }
        throw lastError
    }

    private func fetchOnce(host: String, apiKey key: String) async throws -> ProviderUsage {
        var request = URLRequest(url: URL(string: "https://\(host)\(Self.quotaPath)")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request, maximumBytes: maximumPayloadSize)
        } catch let error as GLMClientError {
            throw error
        } catch let error as BoundedTransportError {
            throw Self.mapTransportError(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GLMClientError.networkFailure
        }

        if let statusError = GLMClientError.httpStatus(response.statusCode) {
            throw statusError
        }

        let envelope: QuotaEnvelope
        do {
            envelope = try JSONDecoder().decode(QuotaEnvelope.self, from: data)
        } catch {
            throw GLMClientError.malformedResponse
        }
        return try Self.provider(from: envelope, fetchedAt: now())
    }

    private static func provider(from envelope: QuotaEnvelope, fetchedAt: Date) throws -> ProviderUsage {
        var session: UsageLine?
        var weekly: UsageLine?
        for limit in envelope.data?.limits ?? [] {
            guard let type = limit.type,
                  type == "TOKENS_LIMIT" || type == "CREDIT_LIMIT",
                  let percentage = limit.percentage else { continue }
            let used = min(max(percentage, 0), 100)
            let resetsAt = limit.nextResetTime.map { Date(timeIntervalSince1970: $0 / 1_000) }
            switch limit.unit {
            case 3:
                session = UsageLine(
                    type: "progress", label: "Session",
                    used: used, limit: 100,
                    resetsAt: resetsAt, periodDurationMs: sessionWindowMs,
                    value: nil, subtitle: nil
                )
            case 6:
                weekly = UsageLine(
                    type: "progress", label: "Weekly",
                    used: used, limit: 100,
                    resetsAt: resetsAt, periodDurationMs: weeklyWindowMs,
                    value: nil, subtitle: nil
                )
            default:
                continue
            }
        }
        guard session != nil || weekly != nil else { throw GLMClientError.quotaMissing }
        return ProviderUsage(
            providerId: "glm",
            displayName: "GLM",
            plan: envelope.data?.level,
            lines: [session, weekly].compactMap { $0 },
            fetchedAt: fetchedAt
        )
    }

    static func validatedAPIKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.utf8.count <= 8_192,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GLMClientError.invalidLocalKey
        }
        return key
    }

    private static func mapTransportError(_ error: BoundedTransportError) -> GLMClientError {
        switch error {
        case .redirectRejected: .redirectRejected
        case .responseTooLarge: .responseTooLarge
        case .unexpectedResponse: .unexpectedHTTPStatus
        }
    }
}

private extension GLMDirectClient {
    struct QuotaEnvelope: Decodable {
        let data: QuotaData?
    }

    struct QuotaData: Decodable {
        let level: String?
        let limits: [QuotaLimit]?
    }

    struct QuotaLimit: Decodable {
        let type: String?
        let unit: Int?
        let percentage: Double?
        let nextResetTime: Double?
    }

    final class HostPreference: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?

        var value: String? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
