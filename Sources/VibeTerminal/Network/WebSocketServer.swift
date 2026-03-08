import Foundation
import Network

// ── WebSocketServer ───────────────────────────────────────────────────────────
//
// Responsabilité unique : gérer le transport WebSocket (écoute, connexions,
// encode/décode). Il ne connaît pas SessionStore.
// Le couplage se fait exclusivement via le callback `onMessage`.
//
// Cycle de vie des connexions :
//   handle() → démarre + écoute  →  stateUpdateHandler retire si .failed/.cancelled
//                                →  cleanupTimer retire les connexions silencieuses
//
// @unchecked Sendable : `connections` et `listener` sont mutés depuis
// le queue réseau (.global). Le caller (@MainActor AppDelegate) ne doit
// pas accéder directement aux propriétés privées.

class WebSocketServer: @unchecked Sendable {

    // ── Callback typé ─────────────────────────────────────────────────────────
    // Branché par AppDelegate vers le SessionStore (prochain prompt).
    // ping/pong sont gérés en interne, jamais propagés ici.
    var onMessage: ((VibeMessage) -> Void)?

    // ── État interne ──────────────────────────────────────────────────────────
    // Dictionnaire UUID → NWConnection pour pouvoir répondre à une connexion
    // précise (ex : pong en réponse au ping de ce client uniquement).
    private var connections:  [UUID: NWConnection] = [:]
    private var listener:     NWListener?
    private var cleanupTimer: DispatchSourceTimer?

    // Port résolu une seule fois au démarrage (immuable ensuite)
    private let port: NWEndpoint.Port

    // ── Résolution du port ────────────────────────────────────────────────────
    // Priorité : variable d'environnement VIBE_PORT (cohérence avec le CLI Node)
    //          → UserDefaults "vibe.wsPort" (configurable via `defaults write`)
    //          → valeur par défaut 8765
    //
    // Exemple pour changer le port :
    //   defaults write com.vibeterminal vibe.wsPort 9000
    static func resolvePort() -> NWEndpoint.Port {
        if let env = ProcessInfo.processInfo.environment["VIBE_PORT"],
           let n = UInt16(env),
           let p = NWEndpoint.Port(rawValue: n) {
            return p
        }
        let stored = UserDefaults.standard.integer(forKey: "vibe.wsPort")
        if stored > 0, stored <= 65535,
           let p = NWEndpoint.Port(rawValue: UInt16(stored)) {
            return p
        }
        return 8765
    }

    init() {
        self.port = Self.resolvePort()
    }

    // ── Démarrage du serveur ──────────────────────────────────────────────────

    func start() {
        let params    = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        // L'app répond automatiquement aux pings réseau bas niveau du protocole WS.
        // Notre ping applicatif (VibeMessage.ping) est géré séparément dans receive().
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            listener = try NWListener(using: params, on: port)
        } catch {
            print("[VibeTerminal] ✗ Impossible de créer le listener : \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            self?.handleListenerState(state)
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener?.start(queue: .global(qos: .userInitiated))
        startCleanupTimer()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            print("[VibeTerminal] ✓ WebSocket actif sur ws://localhost:\(port.rawValue)")

        case .failed(let error):
            // Distinguer "port occupé" des autres erreurs réseau pour guider l'utilisateur.
            // NWError.posix(.EADDRINUSE) = errno 48 sur macOS = Address already in use.
            if case .posix(let code) = error, code == .EADDRINUSE {
                print("""
                [VibeTerminal] ✗ Port \(port.rawValue) déjà utilisé.
                               → Une instance de VibeTerminal tourne peut-être déjà.
                               → Pour changer de port : defaults write com.vibeterminal vibe.wsPort <port>
                               → Puis relancer l'application.
                """)
            } else {
                print("[VibeTerminal] ✗ Serveur en échec : \(error.localizedDescription)")
            }
            listener?.cancel()

        case .cancelled:
            print("[VibeTerminal] Serveur arrêté.")

        default:
            break
        }
    }

    // ── Broadcast : Swift → tous les clients ──────────────────────────────────

    func send(_ message: VibeMessage) {
        guard let data = try? message.encode() else {
            print("[VibeTerminal] Encodage impossible pour le message : \(message)")
            return
        }
        let context = Self.textFrameContext()
        for (_, connection) in connections where connection.state == .ready {
            connection.send(content: data, contentContext: context,
                            isComplete: true, completion: .idempotent)
        }
    }

    // ── Réponse à une connexion précise (ping → pong) ─────────────────────────

    private func send(_ message: VibeMessage, to connection: NWConnection) {
        guard let data = try? message.encode() else { return }
        connection.send(content: data, contentContext: Self.textFrameContext(),
                        isComplete: true, completion: .idempotent)
    }

    // Contexte WebSocket "text frame" — réutilisé à chaque envoi
    private static func textFrameContext() -> NWConnection.ContentContext {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        return NWConnection.ContentContext(identifier: "vibe-msg", metadata: [meta])
    }

    // ── Acceptation d'une connexion entrante ──────────────────────────────────

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        connections[id] = connection
        print("[VibeTerminal] Client connecté [id: \(id.uuidString.prefix(8))…] (\(connections.count) actif(s))")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                print("[VibeTerminal] Connexion \(id.uuidString.prefix(8))… perdue : \(error.localizedDescription)")
                self?.connections.removeValue(forKey: id)
            case .cancelled:
                self?.connections.removeValue(forKey: id)
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        receive(from: connection, id: id)
    }

    // ── Boucle de réception ───────────────────────────────────────────────────

    private func receive(from connection: NWConnection, id: UUID) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                // Erreur de lecture : la connexion sera retirée via stateUpdateHandler
                print("[VibeTerminal] Erreur réception [\(id.uuidString.prefix(8))…] : \(error.localizedDescription)")
                return
            }

            if let data, !data.isEmpty {
                self.handle(data: data, from: connection)
            }

            // Rappel récursif pour continuer à écouter les prochains messages
            self.receive(from: connection, id: id)
        }
    }

    // ── Dispatch des messages décodés ─────────────────────────────────────────

    private func handle(data: Data, from connection: NWConnection) {
        guard let message = VibeMessage.decode(from: data) else {
            // decode() a déjà loggé l'erreur avec le contenu brut
            return
        }

        switch message {
        case .ping:
            // Géré en interne : le CLI envoie des pings applicatifs toutes les 5s.
            // On répond directement à la même connexion sans propager au SessionStore.
            send(.pong, to: connection)

        case .pong:
            // Réponse à un ping qu'on aurait envoyé (usage futur) — ignorée pour l'instant
            break

        default:
            // Tous les messages métier (session:start, session:output, session:end,
            // session:prompt, input:reply) sont délégués au SessionStore via le callback.
            // Task @MainActor car onMessage modifiera des @Published sur le main thread.
            let msg = message
            Task { @MainActor [weak self] in
                self?.onMessage?(msg)
            }
        }
    }

    // ── Nettoyage périodique des connexions silencieuses ──────────────────────
    //
    // stateUpdateHandler ne se déclenche pas toujours quand un client disparaît
    // brutalement (crash, réseau coupé sans FIN TCP). Ce timer retire les
    // connexions dont l'état n'est plus .ready après 30 secondes.
    // Intervalle de 30s : assez fréquent pour libérer les ressources,
    // assez espacé pour ne pas peser sur le CPU.

    private func startCleanupTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.purgeDeadConnections() }
        timer.resume()
        cleanupTimer = timer
    }

    private func purgeDeadConnections() {
        let before = connections.count
        connections = connections.filter { _, conn in conn.state == .ready }
        let removed = before - connections.count
        if removed > 0 {
            print("[VibeTerminal] Nettoyage : \(removed) connexion(s) morte(s) retirée(s) (\(connections.count) active(s))")
        }
    }

    // ── Arrêt propre ──────────────────────────────────────────────────────────

    func stop() {
        cleanupTimer?.cancel()
        cleanupTimer = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
    }
}
