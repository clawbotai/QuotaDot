import AppKit
import SwiftUI

@main
struct QuotaDotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                store: appDelegate.store,
                windowController: appDelegate.windowController,
                language: appDelegate.language,
                providerVisibility: appDelegate.providerVisibility
            )
        } label: {
            HStack(spacing: 4) {
                if let provider = menuBarProvider {
                    if let balance = provider.balance {
                        DeepSeekMenuBarGlyph()
                        Text(QuotaFormatters.compactCNY(balance.toppedUp))
                    } else {
                        MenuBarQuotaGlyph()
                        Text(QuotaFormatters.percent(lowestRemaining(for: provider)))
                    }
                } else {
                    MenuBarQuotaGlyph()
                    Text("--")
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .monospacedDigit()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(menuBarAccessibilityText)
            .help(menuBarAccessibilityText)
        }
        .commands {
            TokenHistoryCommands(language: appDelegate.language)
        }

        Window("QuotaDot", id: "token-history") {
            TokenHistoryView(
                store: appDelegate.historyStore,
                quotaStore: appDelegate.store,
                language: appDelegate.language
            )
                .navigationTitle(appDelegate.language.text("history.title"))
        }
        .defaultSize(width: 940, height: 690)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(
                language: appDelegate.language,
                store: appDelegate.store,
                deepSeekCredentials: appDelegate.deepSeekCredentials,
                glmCredentials: appDelegate.glmCredentials,
                floatingWindowSettings: appDelegate.floatingWindowSettings,
                menuBarProviderSettings: appDelegate.menuBarProviderSettings,
                providerVisibility: appDelegate.providerVisibility,
                windowController: appDelegate.windowController
            )
        }
    }

    private var visibleProviders: [ProviderUsage] {
        appDelegate.store.providers.filter(appDelegate.providerVisibility.isVisible)
    }

    private var menuBarProvider: ProviderUsage? {
        appDelegate.menuBarProviderSettings.provider(from: visibleProviders)
    }

    private func lowestRemaining(for provider: ProviderUsage) -> Double? {
        [provider.session?.remainingPercent, provider.weekly?.remainingPercent]
            .compactMap { $0 }
            .min()
    }

    private var menuBarAccessibilityText: String {
        guard let provider = menuBarProvider else {
            return appDelegate.language.text("menuBar.accessibility.loading")
        }
        if let balance = provider.balance {
            return "\(provider.displayName), \(QuotaFormatters.cny(balance.toppedUp))"
        }
        guard let remaining = lowestRemaining(for: provider) else {
            return appDelegate.language.text("menuBar.accessibility.loading")
        }
        return "\(provider.displayName), " + appDelegate.language.text(
            "menuBar.accessibility.remaining",
            QuotaFormatters.percent(remaining)
        )
    }
}

private struct TokenHistoryCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let language: LanguageSettings

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(language.text("menu.details")) {
                openWindow(id: "token-history")
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let deepSeekCredentials = DeepSeekCredentialManager()
    let glmCredentials = GLMCredentialManager()
    lazy var store: QuotaStore = makeStore()
    let historyStore = TokenHistoryStore()
    let language = LanguageSettings()
    let floatingWindowSettings = FloatingWindowSettings()
    let menuBarProviderSettings = MenuBarProviderSettings()
    let providerVisibility = ProviderVisibilitySettings()
    lazy var windowController = FloatingWindowController(
        store: store,
        language: language,
        settings: floatingWindowSettings,
        providerVisibility: providerVisibility
    )
    private var refreshTask: Task<Void, Never>?
    private var historyLoadTask: Task<Void, Never>?

    private func makeStore() -> QuotaStore {
        QuotaStore(deepSeekCredentials: deepSeekCredentials, glmCredentials: glmCredentials)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        windowController.show()
        refreshTask = Task { await store.start() }
        historyLoadTask = Task { await historyStore.loadIfNeeded() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        historyLoadTask?.cancel()
    }
}

private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    let store: QuotaStore
    let windowController: FloatingWindowController
    let language: LanguageSettings
    let providerVisibility: ProviderVisibilitySettings

    var body: some View {
        let visibleProviders = store.providers.filter(providerVisibility.isVisible)
        if visibleProviders.isEmpty {
            Text(language.text(store.errorMessageKey ?? "menu.loading"))
        } else {
            ForEach(visibleProviders) { provider in
                Text(menuSummary(for: provider))
            }
        }
        Divider()
        Button(language.text("menu.details")) {
            openWindow(id: "token-history")
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        Button(language.text("menu.show")) { windowController.expandAndShow() }
        Button(language.text("menu.refresh")) { Task { await store.refresh() } }
        SettingsLink { Text(language.text("menu.settings")) }
        Divider()
        Button(language.text("menu.quit")) { NSApp.terminate(nil) }
    }

    private func menuSummary(for provider: ProviderUsage) -> String {
        var parts = [provider.displayName]
        if let balance = provider.balance {
            parts.append("\(language.text("balance.topUp")) \(QuotaFormatters.cny(balance.toppedUp))")
            if case .cached = store.deepSeekStatus { parts.append(language.text("balance.cached")) }
        }
        if let session = provider.session { parts.append("5h \(QuotaFormatters.percent(session.remainingPercent))") }
        if let weekly = provider.weekly {
            parts.append("\(language.text("menu.weekly.short")) \(QuotaFormatters.percent(weekly.remainingPercent))")
        }
        return parts.joined(separator: " · ")
    }
}
