import AppKit
import SwiftUI

struct SettingsView: View {
    let language: LanguageSettings
    let store: QuotaStore
    let deepSeekCredentials: DeepSeekCredentialManager
    let glmCredentials: GLMCredentialManager
    let floatingWindowSettings: FloatingWindowSettings
    let menuBarProviderSettings: MenuBarProviderSettings
    let providerVisibility: ProviderVisibilitySettings
    let windowController: FloatingWindowController
    @State private var loginItem = LoginItemManager()
    @State private var deepSeekDraft = ""
    @State private var glmDraft = ""
    @State private var validationMessageKey: String?
    @State private var glmValidationMessageKey: String?
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
                    let visibleProviders = store.providers.filter(providerVisibility.isVisible)
                    Picker(
                        language.text("settings.menuBarProvider"),
                        selection: Binding(
                            get: {
                                let selected = menuBarProviderSettings.selectedProviderId?.lowercased()
                                let visible = visibleProviders.first {
                                    $0.providerId.lowercased() == selected
                                }
                                return visible?.providerId ?? visibleProviders.first?.providerId ?? store.providers[0].providerId
                            },
                            set: { menuBarProviderSettings.selectedProviderId = $0 }
                        )
                    ) {
                        ForEach(visibleProviders) { provider in
                            Text(provider.displayName).tag(provider.providerId)
                        }
                    }

                    providerVisibilitySection
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
                LabeledContent(language.text("settings.quotaSource"), value: "Codex + Claude + Kimi + GLM + DeepSeek Direct")
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

            Section(language.text("glm.settings.section")) {
                LabeledContent(language.text("glm.settings.status")) {
                    Label(glmStatusText, systemImage: glmStatusSymbol)
                        .foregroundStyle(glmStatusColor)
                }

                SecureField(language.text("glm.settings.apiKey"), text: $glmDraft)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)

                if let glmValidationMessageKey {
                    Label(language.text(glmValidationMessageKey), systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button(language.text("glm.settings.getKey")) { openGLMAPIKeys() }
                    Button(language.text("glm.settings.connect")) { connectGLM() }
                        .disabled(glmDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isRefreshing)
                    Button(language.text("glm.settings.retry")) { store.refreshGLM() }
                        .disabled(store.isRefreshing)
                    Spacer()
                    if glmCredentials.hasStoredAPIKey || store.hasPendingGLMCredential || store.glmProvider != nil {
                        Button(language.text("glm.settings.disconnect"), role: .destructive) {
                            disconnectGLM()
                        }
                    }
                }

                Text(language.text("glm.settings.privacy"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 780)
        .onAppear { loginItem.refresh() }
        .onDisappear {
            deepSeekDraft = ""
            glmDraft = ""
            validationMessageKey = nil
            glmValidationMessageKey = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { loginItem.refresh() }
        }
    }

    private var providerVisibilitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language.text("settings.providerVisibility"))
                .font(.callout.weight(.medium))
            ForEach(store.providers) { provider in
                Toggle(isOn: Binding(
                    get: { providerVisibility.isVisible(provider) },
                    set: { isVisible in
                        providerVisibility.setVisible(isVisible, for: provider)
                        if !isVisible {
                            clearMenuBarSelectionIfHidden(provider: provider)
                        }
                    }
                )) {
                    Text(provider.displayName)
                }
            }
        }
        .padding(.top, 8)
    }

    private func clearMenuBarSelectionIfHidden(provider: ProviderUsage) {
        guard menuBarProviderSettings.selectedProviderId?.lowercased() == provider.providerId.lowercased() else { return }
        let fallback = store.providers.first {
            $0.providerId.lowercased() != provider.providerId.lowercased()
                && providerVisibility.isVisible($0)
        }
        menuBarProviderSettings.selectedProviderId = fallback?.providerId
    }

    private func openDeepSeekAPIKeys() {
        guard let url = URL(string: "https://platform.deepseek.com/api_keys") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openGLMAPIKeys() {
        guard let url = URL(string: "https://www.bigmodel.cn/usercenter/proj-mgmt/apikeys") else { return }
        NSWorkspace.shared.open(url)
    }

    private func connectGLM() {
        guard store.connectGLM(apiKey: glmDraft) else {
            glmValidationMessageKey = "glm.settings.invalidKey"
            glmDraft = ""
            return
        }
        glmValidationMessageKey = nil
        glmDraft = ""
    }

    private func disconnectGLM() {
        if !store.disconnectGLM() {
            glmValidationMessageKey = "glm.settings.keychainFailed"
        } else {
            glmValidationMessageKey = nil
        }
        glmDraft = ""
    }

    private var glmStatusText: String {
        switch store.glmStatus {
        case .idle:
            return language.text(glmCredentials.hasStoredAPIKey ? "glm.status.idle" : "glm.status.notConnected")
        case .checking:
            return language.text("glm.status.checking")
        case .live:
            return language.text("glm.status.live")
        case let .failed(error):
            return language.text(glmStatusKey(for: error))
        }
    }

    private func glmStatusKey(for error: GLMErrorKind) -> String {
        switch error {
        case .keyMissing: "glm.status.notConnected"
        case .invalidLocalKey: "glm.status.invalidKey"
        case .credentialStoreFailure: "glm.status.keychainFailed"
        case .unauthorized: "glm.status.expired"
        case .clientRejected: "glm.status.unauthorized"
        case .quotaMissing: "glm.status.quotaMissing"
        case .rateLimited: "glm.status.rateLimited"
        case .serverUnavailable, .networkFailure: "glm.status.network"
        case .unexpectedHTTPStatus, .redirectRejected, .responseTooLarge, .malformedResponse:
            "glm.status.contract"
        }
    }

    private var glmStatusSymbol: String {
        switch store.glmStatus {
        case .live: "checkmark.circle.fill"
        case .checking: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .idle: "circle.dashed"
        }
    }

    private var glmStatusColor: Color {
        switch store.glmStatus {
        case .live: .green
        case .checking, .idle: .secondary
        case .failed: .red
        }
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
