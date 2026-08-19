import AppKit
import SwiftUI

enum QuotaWindowMetrics {
    static let width: CGFloat = 356
    static let headerHeight: CGFloat = 62
    static let footerHeight: CGFloat = 34
    static let quotaCardHeight: CGFloat = 174
    static let quotaCardWithCreditsHeight: CGFloat = 202
    static let balanceCardHeight: CGFloat = 132
    static let emptyStateHeight: CGFloat = 170
    static let dividerHeight: CGFloat = 1
    static let compactBadgeSize: CGFloat = 52
    static let compactSpacing: CGFloat = 8
    static let compactHeight: CGFloat = 56

    static func expandedHeight(providers: [ProviderUsage], hasCodexCredits: Bool) -> CGFloat {
        let content: CGFloat
        if providers.isEmpty {
            content = emptyStateHeight
        } else {
            content = providers.reduce(0) { total, provider in
                if provider.balance != nil { return total + balanceCardHeight }
                let hasCredits = hasCodexCredits && provider.providerId.lowercased() == "codex"
                return total + (hasCredits ? quotaCardWithCreditsHeight : quotaCardHeight)
            } + CGFloat(max(providers.count - 1, 0)) * dividerHeight
        }
        return headerHeight + content + footerHeight
    }

    static func compactWidth(providerCount: Int) -> CGFloat {
        let count = max(providerCount, 1)
        return CGFloat(count) * compactBadgeSize + CGFloat(max(count - 1, 0)) * compactSpacing
    }
}

@MainActor
final class FloatingWindowController: NSObject {
    private let store: QuotaStore
    private let language: LanguageSettings
    private let settings: FloatingWindowSettings
    private let providerVisibility: ProviderVisibilitySettings
    private var panel: NSPanel?
    private var compact = true
    private var hoverMonitor: Any?
    private var pointerTimer: Timer?

    init(
        store: QuotaStore,
        language: LanguageSettings,
        settings: FloatingWindowSettings,
        providerVisibility: ProviderVisibilitySettings
    ) {
        self.store = store
        self.language = language
        self.settings = settings
        self.providerVisibility = providerVisibility
    }

    func show() {
        guard settings.isEnabled else { return }
        guard panel == nil else { panel?.orderFrontRegardless(); return }
        let initialSize = compactSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = makeHostingView(compact: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        position(panel, size: initialSize)
        panel.orderFrontRegardless()
        self.panel = panel
        installHoverMonitor()
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluatePointer() }
        }
    }

    func setEnabled(_ enabled: Bool) {
        settings.isEnabled = enabled
        if enabled {
            show()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func rootView() -> some View {
        FloatingQuotaView(
            store: store,
            language: language,
            providerVisibility: providerVisibility,
            compact: Binding(
                get: { self.compact },
                set: { self.setCompact($0) }
            )
        )
    }

    private func setCompact(_ value: Bool) {
        guard compact != value, let panel else { return }
        compact = value
        let oldTopRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        let size = value ? compactSize : NSSize(width: QuotaWindowMetrics.width, height: expandedHeight)
        let target = NSRect(x: oldTopRight.x - size.width, y: oldTopRight.y - size.height, width: size.width, height: size.height)
        panel.setFrame(target, display: false)
        panel.contentView = makeHostingView(compact: value)
        panel.displayIfNeeded()
    }

    private func makeHostingView(compact: Bool) -> NSView {
        let hosting = NSHostingView(rootView: rootView())
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = !compact
        hosting.layer?.cornerRadius = compact ? 0 : 28
        hosting.layer?.cornerCurve = .continuous
        return hosting
    }

    private var visibleProviders: [ProviderUsage] {
        store.providers.filter(providerVisibility.isVisible)
    }

    private var expandedHeight: CGFloat {
        QuotaWindowMetrics.expandedHeight(
            providers: visibleProviders,
            hasCodexCredits: store.codexResetCredits != nil
        )
    }

    private var compactSize: NSSize {
        NSSize(
            width: QuotaWindowMetrics.compactWidth(providerCount: visibleProviders.count),
            height: QuotaWindowMetrics.compactHeight
        )
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 18, y: visible.maxY - size.height - 18))
    }

    private func installHoverMonitor() {
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.evaluatePointer() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.evaluatePointer()
            return event
        }
    }

    private func evaluatePointer() {
        guard let panel else { return }
        synchronizePanelSize(panel)
        let inside = panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
        if inside && compact {
            setCompact(false)
        } else if !inside && !compact {
            setCompact(true)
        }
    }

    private func synchronizePanelSize(_ panel: NSPanel) {
        let size = compact
            ? compactSize
            : NSSize(width: QuotaWindowMetrics.width, height: expandedHeight)
        guard abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 else { return }
        let topRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        panel.setFrame(
            NSRect(x: topRight.x - size.width, y: topRight.y - size.height, width: size.width, height: size.height),
            display: true
        )
    }

}
