import AppKit
import CryptoKit
import Foundation
import Network
import Security

struct AntigravityOAuthRequest: Sendable {
    static var clientID: String { AntigravityBuildConfig.clientID }
    static var clientSecret: String { AntigravityBuildConfig.clientSecret }
    let state: String
    let verifier: String

    init() throws {
        guard !Self.clientID.isEmpty, !Self.clientSecret.isEmpty else {
            throw AntigravityError.configurationMissing
        }
        var bytes = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AntigravityError.invalidResponse
        }
        state = Data(bytes.prefix(32)).base64URL
        verifier = Data(bytes.suffix(32)).base64URL
    }

    func redirectURI(port: UInt16) -> String { "http://127.0.0.1:\(port)/oauth-callback" }

    func authorizationURL(port: UInt16) -> URL {
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = [
            "client_id": Self.clientID, "response_type": "code", "redirect_uri": redirectURI(port: port),
            "scope": ["cloud-platform", "userinfo.email", "userinfo.profile", "cclog", "experimentsandconfigs"]
                .map { "https://www.googleapis.com/auth/\($0)" }.joined(separator: " "),
            "state": state, "code_challenge": Data(SHA256.hash(data: Data(verifier.utf8))).base64URL,
            "code_challenge_method": "S256", "access_type": "offline", "prompt": "consent"
        ].sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return url.url!
    }

    func callbackCode(target: String) throws -> String {
        guard let url = URLComponents(string: target), url.path == "/oauth-callback",
              let items = url.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state else {
            throw AntigravityError.invalidCallback
        }
        if items.contains(where: { $0.name == "error" }) { throw AntigravityError.authorizationDenied }
        guard items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw AntigravityError.invalidCallback
        }
        return code
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// A short-lived loopback listener; Google sign-in stays in the user's browser.
@MainActor
final class AntigravityOAuth {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var continuation: CheckedContinuation<(code: String, redirectURI: String), Error>?
    private var timeout: Task<Void, Never>?

    func authorize(_ flow: AntigravityOAuthRequest,
                   open: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) async throws -> (code: String, redirectURI: String) {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let server = try NWListener(using: parameters)
        listener = server
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                server.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor in
                        guard let self, self.continuation != nil else { return }
                        switch state {
                        case .ready:
                            guard let port = server.port else { self.finish(.failure(AntigravityError.invalidResponse)); return }
                            if !open(flow.authorizationURL(port: port.rawValue)) {
                                self.finish(.failure(AntigravityError.browserUnavailable))
                            }
                        case let .failed(error): self.finish(.failure(error))
                        default: break
                        }
                    }
                }
                server.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        guard let self, self.continuation != nil else { connection.cancel(); return }
                        self.connections.append(connection)
                        connection.start(queue: .main)
                        self.receive(connection, buffer: Data(), flow: flow, port: server.port!.rawValue)
                    }
                }
                server.start(queue: .main)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(300)) }
                    catch { return }
                    self?.finish(.failure(AntigravityError.authorizationTimedOut))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func receive(_ connection: NWConnection, buffer: Data, flow: AntigravityOAuthRequest, port: UInt16) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.continuation != nil else { connection.cancel(); return }
                let accumulated = buffer + (data ?? Data())
                guard error == nil, accumulated.count <= 16384 else { connection.cancel(); return }
                guard let text = String(data: accumulated, encoding: .utf8), text.contains("\r\n\r\n") else {
                    if complete { connection.cancel() }
                    else { self.receive(connection, buffer: accumulated, flow: flow, port: port) }
                    return
                }
                let parts = text.components(separatedBy: "\r\n")[0].split(separator: " ")
                let result: Result<(code: String, redirectURI: String), Error>
                do {
                    guard parts.count == 3, parts[0] == "GET" else { throw AntigravityError.invalidCallback }
                    result = .success((try flow.callbackCode(target: String(parts[1])), flow.redirectURI(port: port)))
                } catch AntigravityError.invalidCallback {
                    self.respond(connection, status: "400 Bad Request", message: "Invalid callback.")
                    return // Unrelated requests must not terminate the pending sign-in.
                } catch { result = .failure(error) }
                let message = "Authorization received. Return to QuotaDot. / 已收到授权回调，请返回 QuotaDot。"
                let body = Data(message.utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in
                    Task { @MainActor in self.finish(result) }
                })
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, message: String) {
        let body = Data(message.utf8)
        connection.send(content: Data("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ result: Result<(code: String, redirectURI: String), Error>) {
        let pending = continuation
        continuation = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        timeout?.cancel()
        timeout = nil
        pending?.resume(with: result)
    }
}
