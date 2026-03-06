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
                print("[VibeTerminal] Serveur WebSocket actif sur ws://localhost:8765")
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

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        print("[VibeTerminal] Nouveau client connecté")

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(_) = state {
                self?.connections.removeAll { $0 === connection }
            }
            if case .cancelled = state {
                self?.connections.removeAll { $0 === connection }
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        receive(from: connection)
    }

    private func receive(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            if let error = error {
                print("[VibeTerminal] Erreur réception: \(error)")
                return
            }

            if let data = data, !data.isEmpty,
               let text = String(data: data, encoding: .utf8),
               let self {
                Task { @MainActor in self.model.handleMessage(text) }
            }

            // Continuer à écouter
            self?.receive(from: connection)
        }
    }
}
