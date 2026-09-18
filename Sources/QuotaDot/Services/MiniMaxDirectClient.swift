import Foundation

protocol MiniMaxUsageClient: Sendable {
    func fetch(apiKey: String) async throws -> ProviderUsage
}

enum MiniMaxClientError: Error, Sendable, Equatable {
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

struct MiniMaxDirectClient: MiniMaxUsageClient {
    static let cnHost = "api.minimaxi.com"
    static let globalHost = "api.minimax.io"
    private static let remainsPath = "/v1/api/openplatform/coding_plan/remains"
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
        self.transport = transport ?? URLSessionBoundedTransport(statusError: { MiniMaxClientError.httpStatus($0) })
        self.now = now
    }

    func fetch(apiKey: String) async throws -> ProviderUsage {
        let key = try Self.validatedAPIKey(apiKey)

        // Prefer the mainland endpoint; remember whichever host last answered
        // so later refreshes skip a known-broken region first.
        let primary = lastSuccessfulHost.value ?? Self.cnHost
        let secondary = primary == Self.cnHost ? Self.globalHost : Self.cnHost
        var lastError = MiniMaxClientError.networkFailure
        for (index, host) in [primary, secondary].enumerated() {
            do {
                let provider = try await fetchOnce(host: host, apiKey: key)
                lastSuccessfulHost.value = host
                return provider
            } catch let error as MiniMaxClientError {
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
        var request = URLRequest(url: URL(string: "https://\(host)\(Self.remainsPath)")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request, maximumBytes: maximumPayloadSize)
        } catch let error as MiniMaxClientError {
            throw error
        } catch let error as BoundedTransportError {
            throw Self.mapTransportError(error)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MiniMaxClientError.networkFailure
        }

        if let statusError = MiniMaxClientError.httpStatus(response.statusCode) {
            throw statusError
        }

        let envelope: RemainsEnvelope
        do {
            envelope = try JSONDecoder().decode(RemainsEnvelope.self, from: data)
        } catch {
            throw MiniMaxClientError.malformedResponse
        }
        return try Self.provider(from: envelope, fetchedAt: now())
    }

    private static func provider(from envelope: RemainsEnvelope, fetchedAt: Date) throws -> ProviderUsage {
        if let status = envelope.baseResp?.statusCode, status != 0 {
            // The gateway reports auth failures in-band with HTTP 200.
            throw status == 1004 ? MiniMaxClientError.unauthorized : MiniMaxClientError.clientRejected
        }
        guard let general = (envelope.modelRemains ?? []).first(where: { $0.modelName == "general" }) else {
            throw MiniMaxClientError.quotaMissing
        }

        // MiniMax reports remaining percentages; UsageLine models usage, so
        // invert before clamping to the 0...100 progress scale.
        var session: UsageLine?
        if let remaining = general.currentIntervalRemainingPercent {
            session = UsageLine(
                type: "progress", label: "Session",
                used: 100 - min(max(remaining, 0), 100), limit: 100,
                resetsAt: general.endTime.map { Date(timeIntervalSince1970: $0 / 1_000) },
                periodDurationMs: sessionWindowMs,
                value: nil, subtitle: nil
            )
        }
        // Weekly only applies when the plan enforces a weekly cap; status 3
        // marks uncapped plans whose remaining value stays pinned at 100.
        var weekly: UsageLine?
        if general.currentWeeklyStatus == 1, let remaining = general.currentWeeklyRemainingPercent {
            weekly = UsageLine(
                type: "progress", label: "Weekly",
                used: 100 - min(max(remaining, 0), 100), limit: 100,
                resetsAt: general.weeklyEndTime.map { Date(timeIntervalSince1970: $0 / 1_000) },
                periodDurationMs: weeklyWindowMs,
                value: nil, subtitle: nil
            )
        }
        guard session != nil || weekly != nil else { throw MiniMaxClientError.quotaMissing }
        return ProviderUsage(
            providerId: "minimax",
            displayName: "MiniMax",
            plan: nil,
            lines: [session, weekly].compactMap { $0 },
            fetchedAt: fetchedAt
        )
    }

    static func validatedAPIKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.utf8.count <= 8_192,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MiniMaxClientError.invalidLocalKey
        }
        return key
    }

    private static func mapTransportError(_ error: BoundedTransportError) -> MiniMaxClientError {
        switch error {
        case .redirectRejected: .redirectRejected
        case .responseTooLarge: .responseTooLarge
        case .unexpectedResponse: .unexpectedHTTPStatus
        }
    }
}

private extension MiniMaxDirectClient {
    struct RemainsEnvelope: Decodable {
        let baseResp: BaseResp?
        let modelRemains: [ModelRemains]?

        enum CodingKeys: String, CodingKey {
            case baseResp = "base_resp"
            case modelRemains = "model_remains"
        }
    }

    struct BaseResp: Decodable {
        let statusCode: Int?
        let statusMsg: String?

        enum CodingKeys: String, CodingKey {
            case statusCode = "status_code"
            case statusMsg = "status_msg"
        }
    }

    struct ModelRemains: Decodable {
        let modelName: String?
        let currentIntervalRemainingPercent: Double?
        let endTime: Double?
        let currentWeeklyStatus: Int?
        let currentWeeklyRemainingPercent: Double?
        let weeklyEndTime: Double?

        enum CodingKeys: String, CodingKey {
            case modelName = "model_name"
            case currentIntervalRemainingPercent = "current_interval_remaining_percent"
            case endTime = "end_time"
            case currentWeeklyStatus = "current_weekly_status"
            case currentWeeklyRemainingPercent = "current_weekly_remaining_percent"
            case weeklyEndTime = "weekly_end_time"
        }
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
