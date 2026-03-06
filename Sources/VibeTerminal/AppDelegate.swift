import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: VibePanel?
    let outputModel = TerminalOutputModel()
    var wsServer: WebSocketServer?
    var statusItem: NSStatusItem?
    var globalEventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView().environmentObject(outputModel)
        panel = VibePanel(contentView: AnyView(contentView))
        panel?.orderFrontRegardless()

        wsServer = WebSocketServer(model: outputModel)
        wsServer?.start()

        setupStatusBar()
        setupGlobalShortcut()
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
        // Demande l'accès Accessibilité si pas encore accordé
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if trusted {
            registerGlobalHotkey()
        } else {
            // Réessaie après que l'utilisateur ait accordé la permission
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                if AXIsProcessTrusted() { self?.registerGlobalHotkey() }
            }
        }
    }

    private func registerGlobalHotkey() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Option+Space : keyCode 49 + .option
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            else { return }

            DispatchQueue.main.async { self?.togglePanel() }
        }
    }

    // ── Toggle visibilité ──────────────────────────────────────────────────────

    @objc func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
