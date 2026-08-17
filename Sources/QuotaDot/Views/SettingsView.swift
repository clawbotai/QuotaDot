import AppKit
import SwiftUI

struct SettingsView: View {
    let language: LanguageSettings
    let store: QuotaStore
    let deepSeekCredentials: DeepSeekCredentialManager
    let floatingWindowSettings: FloatingWindowSettings
    let menuBarProviderSettings: MenuBarProviderSettings
    let windowController: FloatingWindowController
    @State private var loginItem = LoginItemManager()
    @State private var deepSeekDraft = ""
    @State private var validationMessageKey: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section(language.text("settings.general")) {
                Picker(
                    language.text("settings.language"),
                    selection: Binding(
                        get: { language.language },
                        set: { language.language = $0 }
                    )
                ) {
                    Text(language.text("settings.chinese")).tag(AppLanguage.simplifiedChinese)
                    Text(language.text("settings.english")).tag(AppLanguage.english)
                }
                .pickerStyle(.segmented)

                if !store.providers.isEmpty {
                    Picker(
                        language.text("settings.menuBarProvider"),
                        selection: Binding(
                            get: {
                                menuBarProviderSettings.provider(from: store.providers)?.providerId
                                    ?? store.providers[0].providerId
                            },
                            set: { menuBarProviderSettings.selectedProviderId = $0 }
                        )
                    ) {
                        ForEach(store.providers) { provider in
                            Text(provider.displayName).tag(provider.providerId)
                        }
                    }
                }

                Toggle(isOn: Binding(
                    get: { floatingWindowSettings.isEnabled },
                    set: { windowController.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("settings.floatingWindow"))
                        Text(language.text("settings.floatingWindow.detail"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle(isOn: Binding(
                    get: { loginItem.isRegistered },
                    set: { loginItem.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("settings.launchAtLogin"))
                        Text(language.text("settings.launchAtLogin.detail"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent(language.text("settings.systemStatus"), value: loginItem.statusText(language: language))

                if loginItem.requiresApproval {
                    HStack(spacing: 10) {
                        Label(language.text("settings.approvalRequired"), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button(language.text("settings.openLoginItems")) { loginItem.openSystemSettings() }
                    }
                    .font(.caption)
                }

                if let errorMessage = loginItem.errorMessage {
                    Label(errorMessage, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(language.text("settings.data")) {
                LabeledContent(language.text("settings.quotaSource"), value: "Codex + Claude + Kimi + DeepSeek Direct")
                LabeledContent(language.text("settings.refreshRate"), value: language.text("settings.refreshRate.value"))
                Text(language.text("settings.privacy"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(language.text("deepseek.settings.section")) {
                LabeledContent(language.text("deepseek.settings.status")) {
                    Label(deepSeekStatusText, systemImage: deepSeekStatusSymbol)
                        .foregroundStyle(deepSeekStatusColor)
                }

                SecureField(language.text("deepseek.settings.apiKey"), text: $deepSeekDraft)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)

                if let validationMessageKey {
                    Label(language.text(validationMessageKey), systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button(language.text("deepseek.settings.getKey")) { openDeepSeekAPIKeys() }
                    Button(language.text("deepseek.settings.connect")) { connectDeepSeek() }
                        .disabled(deepSeekDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isRefreshing)
                    Button(language.text("deepseek.settings.retry")) { store.refreshDeepSeek() }
                        .disabled(store.isRefreshing)
                    Spacer()
                    if deepSeekCredentials.hasStoredAPIKey || store.hasPendingDeepSeekCredential || store.deepSeekProvider != nil {
                        Button(language.text("deepseek.settings.disconnect"), role: .destructive) {
                            disconnectDeepSeek()
                        }
                    }
                }

                Text(language.text("deepseek.settings.privacy"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 500)
        .onAppear { loginItem.refresh() }
        .onDisappear {
            deepSeekDraft = ""
            validationMessageKey = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { loginItem.refresh() }
        }
    }

    private func openDeepSeekAPIKeys() {
        guard let url = URL(string: "https://platform.deepseek.com/api_keys") else { return }
        NSWorkspace.shared.open(url)
    }

    private func connectDeepSeek() {
        guard store.connectDeepSeek(apiKey: deepSeekDraft) else {
            validationMessageKey = "deepseek.settings.invalidKey"
            deepSeekDraft = ""
            return
        }
        validationMessageKey = nil
        deepSeekDraft = ""
    }

    private func disconnectDeepSeek() {
        if !store.disconnectDeepSeek() {
            validationMessageKey = "deepseek.settings.keychainFailed"
        } else {
            validationMessageKey = nil
        }
        deepSeekDraft = ""
    }

    private var deepSeekStatusText: String {
        switch store.deepSeekStatus {
        case .idle:
            return language.text(deepSeekCredentials.hasStoredAPIKey ? "deepseek.status.idle" : "deepseek.status.notConnected")
        case .checking:
            return language.text("deepseek.status.checking")
        case .live:
            return language.text("deepseek.status.live")
        case let .cached(_, currentError, contractFailure, expiry):
            if let contractFailure, let expiry {
                return language.text(
                    "deepseek.status.cachedContract",
                    language.text(statusKey(for: contractFailure)),
                    QuotaFormatters.reset(language: language.language).string(from: expiry),
                    language.text(statusKey(for: currentError))
                )
            }
            return language.text("deepseek.status.cached")
        case let .failed(error):
            return language.text(statusKey(for: error))
        }
    }

    private func statusKey(for error: DeepSeekErrorKind) -> String {
        switch error {
        case .keyMissing: "deepseek.status.notConnected"
        case .invalidLocalKey: "deepseek.status.invalidKey"
        case .credentialStoreFailure: "deepseek.status.keychainFailed"
        case .unauthorized: "deepseek.status.expired"
        case .clientRejected: "deepseek.status.unauthorized"
        case .cnyBalanceMissing: "deepseek.status.cnyMissing"
        case .rateLimited: "deepseek.status.rateLimited"
        case .serverUnavailable, .networkFailure: "deepseek.status.network"
        case .unexpectedHTTPStatus, .redirectRejected, .responseTooLarge, .malformedResponse:
            "deepseek.status.contract"
        }
    }

    private var deepSeekStatusSymbol: String {
        switch store.deepSeekStatus {
        case .live: "checkmark.circle.fill"
        case .checking: "arrow.triangle.2.circlepath"
        case .cached: "clock.badge.exclamationmark"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "circle.dashed"
        }
    }

    private var deepSeekStatusColor: Color {
        switch store.deepSeekStatus {
        case .live: .green
        case .checking, .idle: .secondary
        case .cached: .orange
        case .failed: .red
        }
    }
}
