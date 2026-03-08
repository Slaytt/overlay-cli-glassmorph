import Foundation

// ── CommandSession ─────────────────────────────────────────────────────────────
//
// Conforme à Codable pour la persistance JSON dans Application Support.
// Les propriétés calculées (parsedOutput, needsConfirmation, isRunning) ne sont
// pas encodées — elles se recalculent à la demande depuis `output`.

struct CommandSession: Identifiable, Codable {
    let id: String              // sessionId du CLI (UUID string)
    let command: String
    let cwd: String
    let startTime: Date
    var output: String = ""
    var exitCode: Int? = nil    // nil = tué par signal (pas zéro)
    var hasEnded: Bool = false
    var isTruncated: Bool = false

    var isRunning: Bool { !hasEnded }

    // Parsing sémantique calculé à la demande — l'output est déjà propre (ANSI
    // retiré côté Node), OutputParser travaille donc sur du texte UTF-8 pur.
    var parsedOutput: [OutputBlock] {
        OutputParser.parse(output)
    }

    // Détecte si l'output se termine par une demande Y/n interactive.
    var needsConfirmation: Bool {
        let tail = String(output.suffix(600))
        let pattern = #"(\(Y/n\)|\(y/N\)|\[Y/n\]|\[y/N\]|\(yes/no\)|\[yes/no\]|continue\?|proceed\?|\? \[y/n\])"#
        return tail.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // Retourne une copie allégée pour les sessions de plus de 24h :
    // on ne conserve que les 50 dernières lignes afin de ne pas gonfler le fichier.
    func archiveReady() -> CommandSession {
        let ageLimit: TimeInterval = 24 * 3600
        guard Date().timeIntervalSince(startTime) > ageLimit else { return self }

        var archived = self
        let lines = output.components(separatedBy: "\n")
        if lines.count > 50 {
            archived.output      = lines.suffix(50).joined(separator: "\n")
            archived.isTruncated = true
        }
        return archived
    }
}

// ── SessionStore ───────────────────────────────────────────────────────────────
//
// Source de vérité unique pour toutes les sessions actives.
// Reçoit des VibeMessage décodés via handle(_:), met à jour les @Published,
// et persiste les sessions terminées dans Application Support.
//
// Limites mémoire :
//   - 50 sessions max en mémoire (les plus anciennes sont retirées en premier)
//   - 500 lignes max par session (tronqué par le début, isTruncated = true)
//
// Persistance :
//   - Fichier : ~/Library/Application Support/VibeTerminal/sessions.json
//   - Chargement au démarrage (init)
//   - Sauvegarde à chaque session:end
//   - Les sessions > 24h sont compressées à 50 lignes à l'écriture

@MainActor
class SessionStore: ObservableObject {
    @Published var sessions: [CommandSession] = []
    @Published var isDashboardMode: Bool = false {
        didSet { onDashboardToggle?(isDashboardMode) }
    }

    // Closure branchée par AppDelegate pour envoyer une réponse interactive
    // vers le CLI Node via WebSocket (inputReply). Sera câblée au prochain prompt.
    var sendToTerminal: ((String) -> Void)?

    // Callback pour AppDelegate : anime le NSPanel quand le mode change.
    var onDashboardToggle: ((Bool) -> Void)?

    private static let maxSessions    = 50
    private static let maxOutputLines = 500

    // ── Persistance ───────────────────────────────────────────────────────────

    // ~/Library/Application Support/VibeTerminal/sessions.json
    // FileManager.SearchPathDomainMask.userDomainMask → dossier de l'utilisateur courant.
    // .applicationSupportDirectory → ~/Library/Application Support (sandboxé ou non).
    private static let storageURL: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("VibeTerminal", isDirectory: true)
            .appendingPathComponent("sessions.json")
    }()

    // JSONEncoder/Decoder partagés — `.iso8601` pour que les Date soient lisibles
    // dans le fichier JSON (ex: "2026-03-07T14:32:00Z") plutôt qu'un Double opaque.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy  = .iso8601
        e.outputFormatting      = .prettyPrinted   // lisibilité du fichier sur disque
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // ── Init ──────────────────────────────────────────────────────────────────

    init() {
        sessions = Self.loadFromDisk()
    }

    // ── Chargement ────────────────────────────────────────────────────────────

    private static func loadFromDisk() -> [CommandSession] {
        let url = storageURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Première utilisation — pas d'erreur, juste un historique vide.
            return []
        }
        do {
            let data = try Data(contentsOf: url)
            let loaded = try decoder.decode([CommandSession].self, from: data)
            print("[SessionStore] \(loaded.count) session(s) chargée(s) depuis le disque.")
            return loaded
        } catch {
            // Fichier corrompu ou format obsolète — on repart de zéro sans crasher.
            print("[SessionStore] Impossible de lire l'historique : \(error.localizedDescription)")
            return []
        }
    }

    // ── Sauvegarde ────────────────────────────────────────────────────────────

    private func saveToDisk() {
        let url = Self.storageURL
        let dir = url.deletingLastPathComponent()

        // Créer ~/Library/Application Support/VibeTerminal/ si absent.
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        } catch {
            print("[SessionStore] Impossible de créer le dossier de persistance : \(error.localizedDescription)")
            return
        }

        // Compresser les sessions de plus de 24h avant d'écrire.
        let toSave = sessions.map { $0.archiveReady() }

        do {
            let data = try Self.encoder.encode(toSave)
            try data.write(to: url, options: .atomic)
            // .atomic : écrit dans un fichier temporaire puis renomme — évite la
            // corruption si l'app plante pendant l'écriture.
        } catch {
            print("[SessionStore] Impossible de sauvegarder l'historique : \(error.localizedDescription)")
        }
    }

    // ── Dispatch des messages WebSocket ───────────────────────────────────────

    func handle(_ message: VibeMessage) {
        switch message {

        case .sessionStart(let sessionId, let command, let cwd, let timestamp):
            let session = CommandSession(
                id:        sessionId,
                command:   command,
                cwd:       cwd,
                startTime: Date(timeIntervalSince1970: timestamp)
            )
            sessions.append(session)
            if sessions.count > Self.maxSessions {
                sessions.removeFirst()
            }

        case .sessionOutput(let sessionId, let data):
            guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else {
                print("[SessionStore] sessionOutput reçu pour sessionId inconnu : \(sessionId.prefix(8))…")
                return
            }
            sessions[idx].output += data
            if sessions[idx].output.count > 10000 {
                sessions[idx].output = String(sessions[idx].output.suffix(8000))
                sessions[idx].isTruncated = true
            }
            let lines = sessions[idx].output.components(separatedBy: "\n")
            if lines.count > Self.maxOutputLines {
                sessions[idx].output = lines.suffix(Self.maxOutputLines).joined(separator: "\n")
                sessions[idx].isTruncated = true
            }

        case .sessionEnd(let sessionId, let exitCode, _):
            guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else {
                print("[SessionStore] sessionEnd reçu pour sessionId inconnu : \(sessionId.prefix(8))…")
                return
            }
            sessions[idx].exitCode = exitCode
            sessions[idx].hasEnded = true
            // Sauvegarder uniquement quand une session se termine — pas à chaque
            // chunk d'output (qui peut arriver des centaines de fois par seconde).
            saveToDisk()

        case .sessionPrompt(let sessionId, _, _):
            _ = sessionId

        case .inputReply, .ping, .pong:
            break
        }
    }

    // ── Actions UI ────────────────────────────────────────────────────────────

    func clear() {
        sessions.removeAll()
    }

    // Supprime l'historique en mémoire et le fichier sur disque.
    func clearHistory() {
        sessions.removeAll()
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            print("[SessionStore] Historique supprimé.")
        } catch {
            print("[SessionStore] Impossible de supprimer l'historique : \(error.localizedDescription)")
        }
    }
}
