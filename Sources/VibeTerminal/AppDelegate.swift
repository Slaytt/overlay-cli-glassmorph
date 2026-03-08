import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: VibePanel?
    let outputModel = SessionStore()
    var wsServer: WebSocketServer?
    var statusItem: NSStatusItem?
    var globalEventMonitor: Any?

    // Frame sauvegardée avant de passer en mode dashboard
    private var compactFrame = NSRect(x: 0, y: 0, width: 700, height: 480)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView().environmentObject(outputModel)
        panel = VibePanel(contentView: AnyView(contentView))
        panel?.orderFrontRegardless()

        wsServer = WebSocketServer()
        wsServer?.start()

        // Tous les messages métier sont délégués au SessionStore.
        // ping/pong sont gérés en interne par WebSocketServer, jamais propagés ici.
        wsServer?.onMessage = { [weak self] message in
            self?.outputModel.handle(message)
        }

        // TODO(prochain-prompt) : brancher sendToTerminal via SessionStore
        // pour obtenir le sessionId courant et envoyer un .inputReply(sessionId:text:).

        // Callback pour animer la fenêtre quand le mode dashboard change
        outputModel.onDashboardToggle = { [weak self] enabled in
            self?.setDashboardMode(enabled)
        }

        setupStatusBar()
        setupGlobalShortcut()
    }

    // ── Dashboard : animation du NSPanel ──────────────────────────────────────

    func setDashboardMode(_ enabled: Bool) {
        guard let panel, let screen = NSScreen.main else { return }

        if enabled {
            compactFrame = panel.frame
            let target = screen.visibleFrame.insetBy(dx: 32, dy: 32)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.38
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(compactFrame, display: true)
            }
        }
    }

    // ── Status bar ─────────────────────────────────────────────────────────────

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "◈"
            button.toolTip = "VibeTerminal (Option+Space)"
            button.target = self
            button.action = #selector(togglePanel)
        }
    }

    // ── Raccourci global Option+Space ──────────────────────────────────────────

    func setupGlobalShortcut() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted {
            registerGlobalHotkey()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if AXIsProcessTrusted() { self?.registerGlobalHotkey() }
            }
        }
    }

    private func registerGlobalHotkey() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            else { return }
            DispatchQueue.main.async { self?.togglePanel() }
        }
    }

    @objc func togglePanel() {
        guard let panel else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
