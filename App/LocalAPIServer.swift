import Foundation
import Network
import ParloCore

/// Listens on 127.0.0.1:47821 for `LocalAPI` requests while Settings → General → "Local transcription
/// for other apps" is on. Loopback only: nothing on the network can reach it. One request per
/// connection; the reply closes it.
@MainActor
final class LocalAPIServer {
    /// Turns audio bytes into Parlo's finished text. Throws to answer 422/500 with the message.
    typealias Handler = @MainActor (_ audio: Data, _ filename: String, _ language: String?) async throws -> String

    private var listener: NWListener?
    private let handler: Handler
    private(set) var problem: String?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isRunning: Bool { listener != nil }

    func setEnabled(_ on: Bool) {
        on ? start() : stop()
    }

    private func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: LocalAPI.port)!)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    if case let .failed(error) = state {
                        problem = "Local transcription couldn't start on port \(LocalAPI.port): \(error.localizedDescription)"
                        self.listener?.cancel()
                        self.listener = nil
                    } else if case .ready = state {
                        problem = nil
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            problem = "Local transcription couldn't start: \(error.localizedDescription)"
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        problem = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] chunk, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return connection.cancel() }
                var data = buffer
                if let chunk { data.append(chunk) }
                switch LocalAPI.frame(data) {
                case .incomplete:
                    if isComplete || error != nil { return connection.cancel() }
                    receive(connection, buffer: data)
                case let .invalid(status, message):
                    send(LocalAPI.error(status: status, message), on: connection)
                case let .request(request):
                    await respond(to: request, on: connection)
                }
            }
        }
    }

    private func respond(to request: LocalAPI.Request, on connection: NWConnection) async {
        switch LocalAPI.route(request) {
        case .health:
            send(LocalAPI.response(status: 200, json: ["status": "ok", "app": "parlo"]), on: connection)
        case let .reject(status, message):
            send(LocalAPI.error(status: status, message), on: connection)
        case let .transcribe(audio, filename, language):
            do {
                let text = try await handler(audio, filename, language)
                send(LocalAPI.response(status: 200, json: ["text": text]), on: connection)
            } catch {
                send(LocalAPI.error(status: 422, error.localizedDescription), on: connection)
            }
        }
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
