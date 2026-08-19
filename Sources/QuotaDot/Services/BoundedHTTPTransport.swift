import Foundation

enum BoundedTransportError: Error, Sendable, Equatable {
    case redirectRejected
    case responseTooLarge
    case unexpectedResponse
}

protocol BoundedHTTPTransporting: Sendable {
    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse)
}

/// Shared hardened transport: ephemeral session, no redirects, a hard body
/// size cap, and caller-injected HTTP status classification.
struct URLSessionBoundedTransport: BoundedHTTPTransporting {
    private let configurationFactory: @Sendable () -> URLSessionConfiguration
    private let statusError: @Sendable (Int) -> (any Error)?

    init(
        statusError: @escaping @Sendable (Int) -> (any Error)?,
        configurationFactory: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }
    ) {
        self.configurationFactory = configurationFactory
        self.statusError = statusError
    }

    func data(for request: URLRequest, maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let delegate = BoundedSessionDelegate(
            maximumBytes: maximumBytes,
            configuration: configurationFactory(),
            statusError: statusError
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
    private let statusError: @Sendable (Int) -> (any Error)?
    private let lock = NSLock()
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var finished = false

    init(
        maximumBytes: Int,
        configuration: URLSessionConfiguration,
        statusError: @escaping @Sendable (Int) -> (any Error)?
    ) {
        self.maximumBytes = maximumBytes
        self.configuration = configuration
        self.statusError = statusError
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
        finish(.failure(BoundedTransportError.redirectRejected))
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
            finish(.failure(BoundedTransportError.unexpectedResponse))
            return
        }
        // Classify authentication and other HTTP failures from headers before
        // enforcing the body limit. A large 401/403 body must never disguise a
        // revoked key as a cacheable response-size contract error.
        if let error = statusError(http.statusCode) {
            completionHandler(.cancel)
            finish(.failure(error))
            return
        }
        if http.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(BoundedTransportError.responseTooLarge))
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
            finish(.failure(BoundedTransportError.responseTooLarge))
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
            finish(.failure(BoundedTransportError.unexpectedResponse))
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
