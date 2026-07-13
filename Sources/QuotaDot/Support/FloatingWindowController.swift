import AppKit
import SwiftUI

@MainActor
final class FloatingWindowController: NSObject {
    private let store: QuotaStore
    private let language: LanguageSettings
    private var panel: NSPanel?
    private var compact = true
    private var hoverMonitor: Any?
    private var pointerTimer: Timer?

    init(store: QuotaStore, language: LanguageSettings) {
        self.store = store
        self.language = language
    }

    func show() {
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

    func expandAndShow() {
        setCompact(false)
        panel?.orderFrontRegardless()
    }

    private func rootView() -> some View {
        FloatingQuotaView(store: store, language: language, compact: Binding(
            get: { self.compact },
            set: { self.setCompact($0) }
        ))
    }

    private func setCompact(_ value: Bool) {
        guard compact != value, let panel else { return }
        compact = value
        let oldTopRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        let size = value ? compactSize : NSSize(width: 356, height: expandedHeight)
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

    private var expandedHeight: CGFloat {
        96 + CGFloat(max(store.providers.count, 1)) * 174 + (store.codexResetCredits == nil ? 0 : 28)
    }

    private var compactSize: NSSize {
        let count = max(store.providers.count, 1)
        return NSSize(width: CGFloat(count * 52 + max(count - 1, 0) * 8), height: 56)
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
        if compact { synchronizeCompactSize(panel) }
        let inside = panel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
        if inside && compact {
            setCompact(false)
        } else if !inside && !compact {
            setCompact(true)
        }
    }

    private func synchronizeCompactSize(_ panel: NSPanel) {
        let size = compactSize
        guard abs(panel.frame.width - size.width) > 0.5 || abs(panel.frame.height - size.height) > 0.5 else { return }
        let topRight = NSPoint(x: panel.frame.maxX, y: panel.frame.maxY)
        panel.setFrame(
            NSRect(x: topRight.x - size.width, y: topRight.y - size.height, width: size.width, height: size.height),
            display: true
        )
    }

}
