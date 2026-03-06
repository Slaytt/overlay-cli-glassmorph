import Foundation
import Network

class WebSocketServer: @unchecked Sendable {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let model: TerminalOutputModel
    let port: NWEndpoint.Port = 8765

    init(model: TerminalOutputModel) {
        self.model = model
    }

    func start() {
        let parameters = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            listener = try NWListener(using: parameters, on: port)
        } catch {
            print("[VibeTerminal] Erreur création listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[VibeTerminal] WebSocket actif sur ws://localhost:8765")
            case .failed(let error):
                print("[VibeTerminal] Serveur en échec: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    // ── Envoi vers tous les clients (Swift → Node) ────────────────────────────

    func send(text: String) {
        guard let data = text.data(using: .utf8) else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "vibe-send", metadata: [metadata])

        for connection in connections where connection.state == .ready {
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .idempotent
            )
        }
    }

    // ── Gestion des connexions entrantes ──────────────────────────────────────

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        print("[VibeTerminal] Client connecté (\(connections.count) actif(s))")

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeAll { $0 === connection }
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        receive(from: connection)
    }

    // ── Réception Node → Swift ────────────────────────────────────────────────

    private func receive(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let error {
                print("[VibeTerminal] Erreur réception: \(error)")
                return
            }
            if let data, !data.isEmpty,
               let text = String(data: data, encoding: .utf8),
               let self {
                Task { @MainActor in self.model.handleMessage(text) }
            }
            self?.receive(from: connection)
        }
    }
}
