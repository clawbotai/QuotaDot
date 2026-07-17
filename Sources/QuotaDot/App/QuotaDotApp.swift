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
                language: appDelegate.language
            )
        } label: {
            HStack(spacing: 3) {
                MenuBarQuotaGlyph()
                Text(QuotaFormatters.percent(appDelegate.store.lowestRemaining))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
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

        Settings { SettingsView(language: appDelegate.language) }
    }

    private var menuBarAccessibilityText: String {
        guard let remaining = appDelegate.store.lowestRemaining else {
            return appDelegate.language.text("menuBar.accessibility.loading")
        }
        return appDelegate.language.text(
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
    let store = QuotaStore()
    let historyStore = TokenHistoryStore()
    let language = LanguageSettings()
    lazy var windowController = FloatingWindowController(store: store, language: language)
    private var refreshTask: Task<Void, Never>?
    private var historyLoadTask: Task<Void, Never>?

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

    var body: some View {
        if store.providers.isEmpty {
            Text(language.text(store.errorMessageKey ?? "menu.loading"))
        } else {
            ForEach(store.providers) { provider in
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
        if let session = provider.session { parts.append("5h \(QuotaFormatters.percent(session.remainingPercent))") }
        if let weekly = provider.weekly {
            parts.append("\(language.text("menu.weekly.short")) \(QuotaFormatters.percent(weekly.remainingPercent))")
        }
        return parts.joined(separator: " · ")
    }
}
