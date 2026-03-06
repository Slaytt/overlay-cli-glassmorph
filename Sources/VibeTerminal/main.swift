import AppKit

// NSApplication.shared doit être initialisé AVANT tout appel sur NSApp
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let delegate = AppDelegate()
app.delegate = delegate
app.run()
