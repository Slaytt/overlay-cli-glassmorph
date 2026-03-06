import Foundation

// ── Model d'une session (une commande lancée) ─────────────────────────────────

struct CommandSession: Identifiable {
    let id = UUID()
    let command: String
    let startTime: Date
    var output: String = ""
    var exitCode: Int? = nil

    var isRunning: Bool { exitCode == nil }

    var statusColor: String {
        guard let code = exitCode else { return "running" }
        return code == 0 ? "success" : "error"
    }

    // Détecte si l'output se termine par une demande Y/n
    var needsConfirmation: Bool {
        let tail = String(output.suffix(600))
        let pattern = #"(\(Y/n\)|\(y/N\)|\[Y/n\]|\[y/N\]|\(yes/no\)|\[yes/no\]|continue\?|proceed\?|\? \[y/n\])"#
        return tail.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// ── ViewModel principal ───────────────────────────────────────────────────────

@MainActor
class TerminalOutputModel: ObservableObject {
    @Published var sessions: [CommandSession] = []
    @Published var currentSessionId: UUID? = nil
    @Published var isDashboardMode: Bool = false {
        didSet { onDashboardToggle?(isDashboardMode) }
    }

    // Closure branchée par AppDelegate pour envoyer des données vers Node via WS
    var sendToTerminal: ((String) -> Void)?

    // Callback pour AppDelegate quand le mode dashboard change
    var onDashboardToggle: ((Bool) -> Void)?

    var currentSession: CommandSession? {
        guard let id = currentSessionId else { return sessions.last }
        return sessions.first { $0.id == id }
    }

    // ── Ingestion des messages WebSocket ─────────────────────────────────────

    func handleMessage(_ text: String) {
        // Réinitialisation : signal de début de commande
        if text == "\u{00}CLEAR\u{00}" { return }

        // Header de commande : "$ npm run build\n"
        if text.hasPrefix("$ ") {
            let cmd = String(text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(2))
            var session = CommandSession(command: cmd, startTime: Date())
            session.output = ""
            sessions.append(session)
            currentSessionId = session.id
            if sessions.count > 30 { sessions.removeFirst() }
            return
        }

        // Signal de fin de commande
        if text.hasPrefix("\n[vibe] Terminé") {
            let codeStr = text.components(separatedBy: "code ").last?
                .trimmingCharacters(in: CharacterSet(charactersIn: ")\n "))
            let code = Int(codeStr ?? "") ?? 0
            updateCurrentSession { $0.exitCode = code }
            return
        }

        // Output normal
        let clean = Self.stripAnsi(text)
        if !clean.isEmpty {
            updateCurrentSession { $0.output += clean }
        }
    }

    func clear() {
        sessions.removeAll()
        currentSessionId = nil
    }

    private func updateCurrentSession(_ transform: (inout CommandSession) -> Void) {
        guard let id = currentSessionId,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        transform(&sessions[idx])
    }

    // ── Nettoyage ANSI/VT100 ─────────────────────────────────────────────────

    static func stripAnsi(_ raw: String) -> String {
        var s = raw
        // OSC sequences
        s = s.replacingOccurrences(
            of: "\u{1B}\\]([^\u{07}\u{1B}]|\u{1B}[^\\\\])*(\u{07}|\u{1B}\\\\)",
            with: "", options: .regularExpression)
        // CSI sequences (couleurs, curseur…)
        s = s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z~]",
            with: "", options: .regularExpression)
        // DCS/PM/APC
        s = s.replacingOccurrences(
            of: "\u{1B}[PX^_].*?\u{1B}\\\\",
            with: "", options: .regularExpression)
        // Autres ESC 2-chars
        s = s.replacingOccurrences(
            of: "\u{1B}[^\\[\\]PX^_]",
            with: "", options: .regularExpression)
        // ESC orphelins
        s = s.replacingOccurrences(of: "\u{1B}", with: "")
        // Caractères de contrôle (sauf \n \t)
        s = s.replacingOccurrences(
            of: "[\\x00-\\x08\\x0B-\\x0C\\x0E-\\x1A\\x1C-\\x1F\\x7F]",
            with: "", options: .regularExpression)
        // \r\n → \n, \r seul → supprimé (overwrite TUI)
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "")
        // Lignes vides excessives
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s
    }
}
