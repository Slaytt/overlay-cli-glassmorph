import Foundation

// ── Protocole WebSocket VibeTerminal ──────────────────────────────────────────
//
// Tous les messages transitent en JSON via WebSocket (localhost:8765).
// Un seul champ discriminant `"type"` détermine la structure du reste du payload.
//
// Choix d'un tagged-union flat (tous les champs au même niveau que "type")
// plutôt qu'un objet `"payload": {...}` imbriqué, pour minimiser la verbosité
// côté Node.js : `ws.send(JSON.stringify({ type: "session:start", sessionId, command }))`.
//
// Choix d'une enum Swift avec associated values plutôt que des structs séparées :
// - Un seul point d'entrée pour encoder/décoder → impossible d'oublier un cas
// - Le switch exhaustif force la gestion de chaque type de message
// - Les associated values documentent précisément le contrat de chaque message

// ── Sous-types ────────────────────────────────────────────────────────────────

/// Type de demande d'interaction de la commande enfant.
/// Utilise rawValue String pour sérialisation JSON directe sans mapping.
enum PromptType: String, Codable {
    /// Demande de confirmation booléenne (Y/n, yes/no…)
    case confirm = "confirm"
    /// Demande de saisie libre (nom de fichier, mot de passe…)
    case input   = "input"
}

// ── Enum principale ───────────────────────────────────────────────────────────

/// Représente tous les messages possibles sur le canal WebSocket.
///
/// Direction des messages :
/// - CLI → Swift : sessionStart, sessionOutput, sessionEnd, sessionPrompt
/// - Swift → CLI : inputReply
/// - Bidirectionnel : ping, pong
enum VibeMessage {

    // ── CLI → Swift ───────────────────────────────────────────────────────────

    /// Une nouvelle commande vient d'être lancée via `vibe <cmd>`.
    /// Toujours le premier message d'une session ; crée un CommandSession côté Swift.
    ///
    /// - sessionId : UUID généré par le CLI, sert de clé primaire pour relier
    ///   les messages suivants à cette session. String plutôt que UUID natif
    ///   pour traverser la frontière JSON sans conversion.
    /// - cwd : répertoire courant au moment du lancement (pour la sidebar projet).
    /// - timestamp : Unix timestamp (secondes) du démarrage, `Double` plutôt que
    ///   `Date` pour garder un format JSON universel sans dépendance au
    ///   décodeur de dates.
    case sessionStart(sessionId: String, command: String, cwd: String, timestamp: Double)

    /// Chunk d'output de la commande, déjà nettoyé des codes ANSI côté Node.
    ///
    /// Le nettoyage ANSI se fait dans le CLI (pas dans Swift) car :
    /// 1. Node a accès au raw PTY byte-by-byte, plus facile à filtrer
    /// 2. Swift reçoit alors du texte UTF-8 propre, sans parsing regex coûteux
    /// 3. Responsabilité unique : le CLI transforme, Swift affiche
    case sessionOutput(sessionId: String, data: String)

    /// La commande s'est terminée (normalement ou suite à un signal).
    ///
    /// - exitCode : nil si le process a été tué par un signal (SIGKILL, SIGTERM…)
    ///   plutôt que de retourner un code, ce qui diffère d'un exit code 0 ou non-nul.
    /// - duration : durée en secondes mesurée côté Node, plus précis que
    ///   la différence Swift entre sessionStart.timestamp et maintenant
    ///   (latence réseau exclue).
    case sessionEnd(sessionId: String, exitCode: Int?, duration: Double)

    /// La commande attend une réponse interactive de l'utilisateur.
    /// Déclenche l'affichage des boutons Y/n ou d'un champ de saisie dans SwiftUI.
    ///
    /// - message : texte brut du prompt (ex: "Overwrite file? (Y/n)") pour
    ///   affichage contextuel dans le HUD.
    case sessionPrompt(sessionId: String, promptType: PromptType, message: String)

    // ── Swift → CLI ───────────────────────────────────────────────────────────

    /// Réponse de l'utilisateur à un sessionPrompt.
    /// Le CLI injecte `text` directement dans le PTY via `term.write(text)`.
    ///
    /// Exemples : "y\r", "n\r", "mon-fichier.swift\r"
    /// Le `\r` (carriage return) simule la touche Entrée dans le PTY.
    case inputReply(sessionId: String, text: String)

    // ── Bidirectionnel ────────────────────────────────────────────────────────

    /// Heartbeat envoyé par l'initiateur (CLI ou Swift) pour détecter
    /// les connexions fantômes. L'autre côté répond immédiatement avec pong.
    case ping

    /// Réponse au ping. Pas de payload nécessaire : la réception suffit
    /// à confirmer que la connexion est vivante.
    case pong
}

// ── Codable custom ────────────────────────────────────────────────────────────
//
// Swift ne peut pas synthétiser Codable pour les enums avec associated values
// ET un discriminant "type" plat dans le JSON. On l'implémente manuellement.
//
// Pattern : on encode/décode tous les champs dans le même conteneur keyed,
// avec "type" comme premier champ (convention lisibilité JSON).

extension VibeMessage: Codable {

    // Toutes les clés JSON possibles à travers tous les types de messages.
    // Un seul CodingKeys couvre l'ensemble du protocole → pas de duplication.
    private enum CodingKeys: String, CodingKey {
        case type
        case sessionId
        case command
        case cwd
        case timestamp
        case data
        case exitCode
        case duration
        case promptType
        case message
        case text
    }

    // ── Encodage ──────────────────────────────────────────────────────────────

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .sessionStart(let sessionId, let command, let cwd, let timestamp):
            try c.encode("session:start", forKey: .type)
            try c.encode(sessionId,       forKey: .sessionId)
            try c.encode(command,         forKey: .command)
            try c.encode(cwd,             forKey: .cwd)
            try c.encode(timestamp,       forKey: .timestamp)

        case .sessionOutput(let sessionId, let data):
            try c.encode("session:output", forKey: .type)
            try c.encode(sessionId,        forKey: .sessionId)
            try c.encode(data,             forKey: .data)

        case .sessionEnd(let sessionId, let exitCode, let duration):
            try c.encode("session:end", forKey: .type)
            try c.encode(sessionId,     forKey: .sessionId)
            // encodeIfPresent évite d'émettre "exitCode": null dans le JSON
            // quand le process a été tué par un signal — le champ est simplement absent.
            try c.encodeIfPresent(exitCode, forKey: .exitCode)
            try c.encode(duration,          forKey: .duration)

        case .sessionPrompt(let sessionId, let promptType, let message):
            try c.encode("session:prompt", forKey: .type)
            try c.encode(sessionId,        forKey: .sessionId)
            try c.encode(promptType,       forKey: .promptType)
            try c.encode(message,          forKey: .message)

        case .inputReply(let sessionId, let text):
            try c.encode("input:reply", forKey: .type)
            try c.encode(sessionId,     forKey: .sessionId)
            try c.encode(text,          forKey: .text)

        case .ping:
            try c.encode("ping", forKey: .type)

        case .pong:
            try c.encode("pong", forKey: .type)
        }
    }

    // ── Décodage ──────────────────────────────────────────────────────────────

    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)

        switch type {
        case "session:start":
            self = .sessionStart(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                command:   try c.decode(String.self, forKey: .command),
                cwd:       try c.decode(String.self, forKey: .cwd),
                timestamp: try c.decode(Double.self, forKey: .timestamp)
            )

        case "session:output":
            self = .sessionOutput(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                data:      try c.decode(String.self, forKey: .data)
            )

        case "session:end":
            self = .sessionEnd(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                // decodeIfPresent retourne nil si le champ est absent du JSON
                // (process tué) ou si sa valeur est null — les deux cas sont valides.
                exitCode:  try c.decodeIfPresent(Int.self, forKey: .exitCode),
                duration:  try c.decode(Double.self, forKey: .duration)
            )

        case "session:prompt":
            self = .sessionPrompt(
                sessionId:  try c.decode(String.self,    forKey: .sessionId),
                promptType: try c.decode(PromptType.self, forKey: .promptType),
                message:    try c.decode(String.self,    forKey: .message)
            )

        case "input:reply":
            self = .inputReply(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                text:      try c.decode(String.self, forKey: .text)
            )

        case "ping":
            self = .ping

        case "pong":
            self = .pong

        default:
            // Type inconnu : on lève une erreur typée plutôt que de silencieusement
            // ignorer pour rendre les bugs de protocol visibles pendant le développement.
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Type de message inconnu : \"\(type)\""
            )
        }
    }
}

// ── API publique ──────────────────────────────────────────────────────────────

extension VibeMessage {

    /// Encode le message en Data JSON prête à être envoyée sur le WebSocket.
    ///
    /// Throws plutôt que retourner Data? : un échec d'encodage est toujours
    /// un bug de programmation (struct non-encodable), pas un cas runtime normal.
    func encode() throws -> Data {
        // JSONEncoder par défaut : pas de pretty-print, clés camelCase.
        // outputFormatting non modifié volontairement : la compacité compte
        // sur un canal WebSocket local à haute fréquence.
        try JSONEncoder().encode(self)
    }

    /// Décode un message depuis les Data reçues sur le WebSocket.
    ///
    /// Retourne nil plutôt que throws pour les callsites qui reçoivent des
    /// données inconnues (futures versions du CLI, messages de debug) :
    /// on log l'erreur et on continue sans crasher.
    static func decode(from data: Data) -> VibeMessage? {
        do {
            return try JSONDecoder().decode(VibeMessage.self, from: data)
        } catch {
            // Log structuré : le message brut aide au débogage de protocol
            let raw = String(data: data, encoding: .utf8) ?? "<non-UTF8>"
            print("[VibeProtocol] Décodage échoué : \(error.localizedDescription) | raw: \(raw.prefix(200))")
            return nil
        }
    }
}

// ── Accesseurs utilitaires ────────────────────────────────────────────────────

extension VibeMessage {

    /// sessionId extrait quel que soit le type de message, nil pour ping/pong.
    /// Pratique pour router un message vers la bonne CommandSession sans switch.
    var sessionId: String? {
        switch self {
        case .sessionStart(let id, _, _, _):  return id
        case .sessionOutput(let id, _):        return id
        case .sessionEnd(let id, _, _):        return id
        case .sessionPrompt(let id, _, _):     return id
        case .inputReply(let id, _):           return id
        case .ping, .pong:                     return nil
        }
    }

    /// Timestamp de sessionStart converti en Date pour l'affichage SwiftUI.
    /// Nil pour tous les autres types de messages.
    var startDate: Date? {
        guard case .sessionStart(_, _, _, let ts) = self else { return nil }
        return Date(timeIntervalSince1970: ts)
    }
}
