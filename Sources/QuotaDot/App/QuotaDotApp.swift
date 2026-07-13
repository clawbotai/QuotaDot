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
            HStack(spacing: 4) {
                MenuBarQuotaGlyph()
                Text(QuotaFormatters.percent(appDelegate.store.lowestRemaining))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
            }
        }

        Settings { SettingsView(language: appDelegate.language) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = QuotaStore()
    let language = LanguageSettings()
    lazy var windowController = FloatingWindowController(store: store, language: language)
    private var refreshTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        windowController.show()
        refreshTask = Task { await store.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
    }
}

private struct MenuBarContent: View {
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
