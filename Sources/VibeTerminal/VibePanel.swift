import AppKit
import SwiftUI

class VibePanel: NSPanel {
    init(contentView: AnyView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 480),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .floating
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.minSize = NSSize(width: 420, height: 280)

        let hosting = NSHostingView(rootView: contentView)
        hosting.autoresizingMask = [.width, .height]
        self.contentView = hosting
        self.center()
    }
}
