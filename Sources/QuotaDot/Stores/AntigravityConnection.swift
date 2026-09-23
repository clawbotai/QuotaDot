import Foundation
import Observation

@MainActor @Observable
final class AntigravityConnection {
    private(set) var provider: ProviderUsage?
    private(set) var statusKey = "antigravity.disconnected"
    private(set) var isBusy = false
    private(set) var hasCredential = false
    private let credentials: any AntigravityCredentialStoring
    private let client: AntigravityDirectClient
    private var oauth: AntigravityOAuth?
    private var generation = 0
    private var disconnected = false

    init(credentials: any AntigravityCredentialStoring = KeychainAntigravityCredentialStore(),
         client: AntigravityDirectClient = AntigravityDirectClient()) {
        self.credentials = credentials
        self.client = client
    }

    func signIn() async { await update(signIn: true) }
    func refresh() async { await update(signIn: false) }

    func disconnect() {
        generation += 1
        disconnected = true
        oauth?.cancel()
        isBusy = false
        provider = nil
        do {
            try credentials.delete()
            hasCredential = false
            statusKey = "antigravity.disconnected"
        } catch { statusKey = "antigravity.keychainError" }
    }

    func cancelSignIn() {
        generation += 1
        oauth?.cancel()
        isBusy = false
        statusKey = "antigravity.cancelled"
    }

    private func update(signIn: Bool) async {
        guard !isBusy, signIn || !disconnected else { return }
        isBusy = true
        let current = generation
        defer { if current == generation { isBusy = false } }
        do {
            var credential: AntigravityCredential
            if signIn {
                statusKey = "antigravity.authorizing"
                provider = nil
                let oauth = AntigravityOAuth()
                self.oauth = oauth
                let flow = try AntigravityOAuthRequest()
                let callback = try await oauth.authorize(flow)
                credential = try await client.exchange(code: callback.code, verifier: flow.verifier, redirectURI: callback.redirectURI)
            } else {
                guard let stored = try credentials.load() else {
                    statusKey = "antigravity.disconnected"
                    return
                }
                credential = stored
                hasCredential = true
                statusKey = "antigravity.refreshing"
                if credential.expiresAt.timeIntervalSinceNow <= 60 {
                    credential = try await client.refresh(credential)
                }
            }
            try Task.checkCancellation()
            guard current == generation else { return }
            try credentials.save(credential)
            hasCredential = true
            disconnected = false
            statusKey = "antigravity.refreshing"
            let fresh = try await client.fetch(accessToken: credential.accessToken)
            try Task.checkCancellation()
            guard current == generation else { return }
            provider = fresh
            statusKey = "antigravity.connected"
        } catch {
            guard current == generation else { return }
            provider = nil
            switch error {
            case AntigravityError.configurationMissing: statusKey = "antigravity.configurationMissing"
            case AntigravityError.quotaUnavailable: statusKey = "antigravity.quotaUnavailable"
            case AntigravityError.projectUnavailable: statusKey = "antigravity.projectUnavailable"
            case AntigravityError.unauthorized: statusKey = "antigravity.unauthorized"
            case AntigravityError.http(403): statusKey = "antigravity.forbidden"
            case AntigravityError.http(429): statusKey = "antigravity.rateLimited"
            case AntigravityError.authorizationDenied: statusKey = "antigravity.denied"
            case AntigravityError.authorizationTimedOut: statusKey = "antigravity.timedOut"
            case is AntigravityCredentialError: statusKey = "antigravity.keychainError"
            case is CancellationError: statusKey = "antigravity.cancelled"
            default: statusKey = "antigravity.failed"
            }
        }
    }
}
