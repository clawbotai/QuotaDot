import Foundation

protocol DeepSeekHTTPTransport: Sendable {
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
}

protocol DeepSeekUsageClient: Sendable {
    func fetch(apiKey: String) async throws -> ProviderUsage
}

enum DeepSeekClientError: Error, Sendable, Equatable {
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
    case cnyBalanceMissing

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

struct DeepSeekDirectClient: DeepSeekUsageClient {
    private let endpoint = URL(string: "https://api.deepseek.com/user/balance")!
    private let maximumPayloadSize = 1_048_576
    private let transport: any DeepSeekHTTPTransport
    private let now: @Sendable () -> Date

    init(
        transport: any DeepSeekHTTPTransport = URLSessionDeepSeekTransport(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.transport = transport
        self.now = now
    }

    func fetch(apiKey: String) async throws -> ProviderUsage {
        let key = try Self.validatedAPIKey(apiKey)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request, maximumBytes: maximumPayloadSize)
        } catch let error as DeepSeekClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DeepSeekClientError.networkFailure
        }

        if let statusError = DeepSeekClientError.httpStatus(response.statusCode) {
            throw statusError
        }

        let envelope: BalanceEnvelope
        do {
            envelope = try JSONDecoder().decode(BalanceEnvelope.self, from: data)
        } catch {
            throw DeepSeekClientError.malformedResponse
        }
        let cny = envelope.balanceInfos.filter { $0.currency.uppercased() == "CNY" }
        guard cny.count == 1 else { throw DeepSeekClientError.cnyBalanceMissing }
        let amount = try Self.parseCNY(cny[0].toppedUpBalance)
        let fetchedAt = now()
        return ProviderUsage(
            providerId: "deepseek",
            displayName: "DeepSeek",
            plan: "API",
            lines: [],
            fetchedAt: fetchedAt,
            balance: ProviderBalance(currency: "CNY", toppedUp: amount, isAvailable: envelope.isAvailable)
        )
    }

    static func validatedAPIKey(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              key.utf8.count <= 8_192,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DeepSeekClientError.invalidLocalKey
        }
        return key
    }

    static func parseCNY(_ raw: String) throws -> Decimal {
        guard raw.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil else {
            throw DeepSeekClientError.malformedResponse
        }
        let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count <= 2, (pieces.count == 1 || pieces[1].count <= 2) else {
            throw DeepSeekClientError.malformedResponse
        }
        let significant = raw.filter(\.isNumber).drop(while: { $0 == "0" })
        guard max(significant.count, 1) <= 28,
              let value = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN,
              value >= 0 else {
            throw DeepSeekClientError.malformedResponse
        }
        return value
    }
}

private extension DeepSeekDirectClient {
    struct BalanceEnvelope: Decodable {
        let isAvailable: Bool
        let balanceInfos: [BalanceInfo]

        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    struct BalanceInfo: Decodable {
        let currency: String
        let toppedUpBalance: String

        enum CodingKeys: String, CodingKey {
            case currency
            case toppedUpBalance = "topped_up_balance"
        }
    }
}

struct URLSessionDeepSeekTransport: DeepSeekHTTPTransport {
    private let configurationFactory: @Sendable () -> URLSessionConfiguration

    init(configurationFactory: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
        self.configurationFactory = configurationFactory
    }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let transport = URLSessionBoundedTransport(
            statusError: { DeepSeekClientError.httpStatus($0) },
            configurationFactory: configurationFactory
        )
        do {
            return try await transport.data(for: request, maximumBytes: maximumBytes)
        } catch let error as BoundedTransportError {
            throw Self.mapTransportError(error)
        }
    }

    private static func mapTransportError(_ error: BoundedTransportError) -> DeepSeekClientError {
        switch error {
        case .redirectRejected: .redirectRejected
        case .responseTooLarge: .responseTooLarge
        case .unexpectedResponse: .unexpectedHTTPStatus
        }
    }
}