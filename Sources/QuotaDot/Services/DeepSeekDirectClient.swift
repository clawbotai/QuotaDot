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
        let delegate = BoundedSessionDelegate(
            maximumBytes: maximumBytes,
            configuration: configurationFactory()
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(request: request, continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }
}

private final class BoundedSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false

    init(maximumBytes: Int, configuration: URLSessionConfiguration) {
        self.maximumBytes = maximumBytes
        self.configuration = configuration
    }

    func start(
        request: URLRequest,
        continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        let currentTask = task
        lock.unlock()
        finish(.failure(CancellationError()))
        currentTask?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(.failure(DeepSeekClientError.redirectRejected))
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(DeepSeekClientError.unexpectedHTTPStatus))
            return
        }
        // Classify authentication and other HTTP failures from headers before
        // enforcing the body limit. A large 401/403 body must never disguise a
        // revoked key as a cacheable response-size contract error.
        if let statusError = DeepSeekClientError.httpStatus(http.statusCode) {
            completionHandler(.cancel)
            finish(.failure(statusError))
            return
        }
        if http.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(DeepSeekClientError.responseTooLarge))
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if buffer.count + data.count > maximumBytes {
            lock.unlock()
            finish(.failure(DeepSeekClientError.responseTooLarge))
            dataTask.cancel()
            return
        }
        buffer.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code == .cancelled { return }
            finish(.failure(error))
            return
        }
        lock.lock()
        let response = self.response
        let data = buffer
        lock.unlock()
        guard let response else {
            finish(.failure(DeepSeekClientError.unexpectedHTTPStatus))
            return
        }
        finish(.success((data, response)))
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        lock.unlock()
        continuation?.resume(with: result)
        session?.finishTasksAndInvalidate()
    }
}
