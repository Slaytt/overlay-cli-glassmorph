import Foundation

// Une session = une commande lancée avec `vibe`
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
}

@MainActor
class TerminalOutputModel: ObservableObject {
    @Published var sessions: [CommandSession] = []
    @Published var currentSessionId: UUID? = nil

    // Session active (dernière en cours ou terminée)
    var currentSession: CommandSession? {
        guard let id = currentSessionId else { return sessions.last }
        return sessions.first { $0.id == id }
    }

    func handleMessage(_ text: String) {
        // Signal de début de commande : \x00CLEAR\x00
        if text == "\u{00}CLEAR\u{00}" {
            return // le CLEAR est suivi du header $ cmd
        }

        // Header de commande envoyé par le CLI : "$ npm run build\n"
        if text.hasPrefix("$ ") {
            let cmd = text.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst(2)
            let session = CommandSession(command: String(cmd), startTime: Date())
            sessions.append(session)
            currentSessionId = session.id
            // Garder max 20 sessions
            if sessions.count > 20 { sessions.removeFirst() }
            return
        }

        // Signal de fin : "[vibe] Terminé (code X)"
        if text.hasPrefix("\n[vibe] Terminé") {
            let codeStr = text.components(separatedBy: "code ").last?
                .trimmingCharacters(in: CharacterSet(charactersIn: ")\n "))
            let code = Int(codeStr ?? "") ?? 0
            updateCurrentSession { $0.exitCode = code }
            return
        }

        // Output normal → append à la session courante
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

    // ── Nettoyage ANSI ────────────────────────────────────────────────────────

    static func stripAnsi(_ raw: String) -> String {
        var s = raw

        // OSC sequences : ESC ] ... BEL/ST
        s = s.replacingOccurrences(
            of: "\u{1B}\\]([^\u{07}\u{1B}]|\u{1B}[^\\\\])*(\u{07}|\u{1B}\\\\)",
            with: "", options: .regularExpression)

        // CSI sequences : ESC [ ... final byte
        s = s.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z~]",
            with: "", options: .regularExpression)

        // DCS / PM / APC sequences
        s = s.replacingOccurrences(
            of: "\u{1B}[PX^_].*?\u{1B}\\\\",
            with: "", options: .regularExpression)

        // Autres ESC 2-chars
        s = s.replacingOccurrences(
            of: "\u{1B}[^\\[\\]PX^_]",
            with: "", options: .regularExpression)

        // ESC orphelins restants
        s = s.replacingOccurrences(of: "\u{1B}", with: "")

        // Caractères de contrôle (sauf \n \t)
        s = s.replacingOccurrences(
            of: "[\\x00-\\x08\\x0B-\\x0C\\x0E-\\x1A\\x1C-\\x1F\\x7F]",
            with: "", options: .regularExpression)

        // \r\n → \n  |  \r seul → SUPPRIMÉ (pas de nouvelle ligne, juste overwrite)
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\r", with: "")

        // Lignes vides excessives
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return s
    }
}
