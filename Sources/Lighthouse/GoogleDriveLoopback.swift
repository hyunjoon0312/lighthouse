import Foundation
import Network

protocol GoogleDriveLoopbackServing: Sendable {
    func start() async throws -> URL
    func waitForCode(timeoutSeconds: TimeInterval) async throws -> String
    func cancel()
}

enum GoogleDriveLoopbackError: Error, LocalizedError, Equatable, Sendable {
    case couldNotStart
    case authorizationDenied
    case timedOut
    case cancelled

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            return "Google 로그인 응답을 받을 로컬 연결을 시작할 수 없습니다."
        case .authorizationDenied:
            return "Google 로그인이 취소되었거나 승인되지 않았습니다."
        case .timedOut:
            return "Google 로그인 대기 시간이 초과되었습니다. 다시 시도해 주세요."
        case .cancelled:
            return "Google 로그인이 취소되었습니다."
        }
    }
}

enum GoogleDriveLoopbackRequest: Equatable, Sendable {
    case code(String)
    case authorizationError
    case invalid

    static func parse(header: Data, expectedState: String) -> GoogleDriveLoopbackRequest {
        guard header.count <= GoogleDriveLoopbackServer.maximumHeaderBytes,
              let text = String(data: header, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first
        else {
            return .invalid
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/1."),
              let url = URL(string: "http://127.0.0.1\(parts[1])"),
              url.path == "/",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return .invalid
        }

        let items = components.queryItems ?? []
        let stateItems = items.filter { $0.name == "state" }
        let codeItems = items.filter { $0.name == "code" }
        let errorItems = items.filter { $0.name == "error" }
        guard stateItems.count == 1, stateItems[0].value == expectedState else {
            return .invalid
        }
        if codeItems.count == 1, errorItems.isEmpty,
           let code = codeItems[0].value, !code.isEmpty {
            return .code(code)
        }
        if errorItems.count == 1, codeItems.isEmpty,
           let error = errorItems[0].value, !error.isEmpty {
            return .authorizationError
        }
        return .invalid
    }
}

final class GoogleDriveLoopbackServer: GoogleDriveLoopbackServing, @unchecked Sendable {
    static let maximumHeaderBytes = 16 * 1024

    private let expectedState: String
    private let queue = DispatchQueue(label: "Lighthouse.GoogleDriveLoopback")
    private let lock = NSLock()

    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var callbackContinuation: CheckedContinuation<String, Error>?
    private var pendingCallback: Result<String, Error>?
    private var timeoutWorkItem: DispatchWorkItem?
    private var stopped = false

    init(expectedState: String) {
        self.expectedState = expectedState
    }

    func start() async throws -> URL {
        if Task.isCancelled {
            cancel()
            throw GoogleDriveLoopbackError.cancelled
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if stopped {
                    lock.unlock()
                    continuation.resume(throwing: GoogleDriveLoopbackError.cancelled)
                    return
                }
                startContinuation = continuation
                lock.unlock()

                do {
                    let parameters = NWParameters.tcp
                    parameters.requiredLocalEndpoint = .hostPort(
                        host: "127.0.0.1",
                        port: NWEndpoint.Port(rawValue: 0)!
                    )
                    let newListener = try NWListener(using: parameters)
                    newListener.stateUpdateHandler = { [weak self] state in
                        self?.handleListenerState(state)
                    }
                    newListener.newConnectionHandler = { [weak self] connection in
                        self?.accept(connection)
                    }

                    lock.lock()
                    if stopped {
                        lock.unlock()
                        newListener.cancel()
                        finishStart(.failure(GoogleDriveLoopbackError.cancelled))
                        return
                    }
                    listener = newListener
                    lock.unlock()
                    newListener.start(queue: queue)
                } catch {
                    finishStart(.failure(GoogleDriveLoopbackError.couldNotStart))
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func waitForCode(timeoutSeconds: TimeInterval = 180) async throws -> String {
        if Task.isCancelled {
            cancel()
            throw GoogleDriveLoopbackError.cancelled
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if stopped, pendingCallback == nil {
                    lock.unlock()
                    continuation.resume(throwing: GoogleDriveLoopbackError.cancelled)
                    return
                }
                if let pendingCallback {
                    self.pendingCallback = nil
                    lock.unlock()
                    continuation.resume(with: pendingCallback)
                    return
                }
                callbackContinuation = continuation
                let workItem = DispatchWorkItem { [weak self] in
                    self?.finishCallback(.failure(GoogleDriveLoopbackError.timedOut))
                }
                timeoutWorkItem = workItem
                lock.unlock()
                queue.asyncAfter(deadline: .now() + max(0, timeoutSeconds), execute: workItem)
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        let start: CheckedContinuation<URL, Error>?
        let callback: CheckedContinuation<String, Error>?
        let currentListener: NWListener?
        let currentConnections: [NWConnection]

        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        start = startContinuation
        startContinuation = nil
        callback = callbackContinuation
        callbackContinuation = nil
        pendingCallback = nil
        currentListener = listener
        listener = nil
        currentConnections = Array(connections.values)
        connections.removeAll()
        lock.unlock()

        currentListener?.cancel()
        currentConnections.forEach { $0.cancel() }
        start?.resume(throwing: GoogleDriveLoopbackError.cancelled)
        callback?.resume(throwing: GoogleDriveLoopbackError.cancelled)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            lock.lock()
            let port = listener?.port
            lock.unlock()
            guard let port,
                  let redirectURL = URL(string: "http://127.0.0.1:\(port.rawValue)/")
            else {
                finishStart(.failure(GoogleDriveLoopbackError.couldNotStart))
                return
            }
            finishStart(.success(redirectURL))
        case .failed:
            finishStart(.failure(GoogleDriveLoopbackError.couldNotStart))
            stopTransport()
        case .cancelled:
            finishStart(.failure(GoogleDriveLoopbackError.cancelled))
        default:
            break
        }
    }

    private func finishStart(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = startContinuation
        startContinuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        lock.lock()
        guard !stopped else {
            lock.unlock()
            connection.cancel()
            return
        }
        connections[id] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.removeConnection(id)
            }
            if case .cancelled = state {
                self?.removeConnection(id)
            }
        }
        connection.start(queue: queue)
        receiveHeader(on: connection, id: id, accumulated: Data())
    }

    private func receiveHeader(on connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self] data, _, complete, error in
            guard let self else { return }
            var header = accumulated
            if let data { header.append(data) }

            if header.count > Self.maximumHeaderBytes {
                respond(status: "431 Request Header Fields Too Large", html: Self.failureHTML, on: connection, id: id)
                return
            }
            if let range = header.range(of: Data("\r\n\r\n".utf8)) {
                let request = GoogleDriveLoopbackRequest.parse(
                    header: header.subdata(in: header.startIndex..<range.upperBound),
                    expectedState: expectedState
                )
                switch request {
                case .code(let code):
                    respond(status: "200 OK", html: Self.successHTML, on: connection, id: id) { [weak self] in
                        self?.finishCallback(.success(code))
                    }
                case .authorizationError:
                    respond(status: "200 OK", html: Self.failureHTML, on: connection, id: id) { [weak self] in
                        self?.finishCallback(.failure(GoogleDriveLoopbackError.authorizationDenied))
                    }
                case .invalid:
                    respond(status: "400 Bad Request", html: Self.failureHTML, on: connection, id: id)
                }
                return
            }
            if complete || error != nil {
                connection.cancel()
                removeConnection(id)
                return
            }
            receiveHeader(on: connection, id: id, accumulated: header)
        }
    }

    private func respond(
        status: String,
        html: String,
        on connection: NWConnection,
        id: UUID,
        completion: (@Sendable () -> Void)? = nil
    ) {
        let body = Data(html.utf8)
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.removeConnection(id)
            completion?()
        })
    }

    private func finishCallback(_ result: Result<String, Error>) {
        let continuation: CheckedContinuation<String, Error>?
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        continuation = callbackContinuation
        callbackContinuation = nil
        if continuation == nil {
            pendingCallback = result
        }
        lock.unlock()

        continuation?.resume(with: result)
        stopTransport()
    }

    private func stopTransport() {
        let currentListener: NWListener?
        let currentConnections: [NWConnection]
        lock.lock()
        currentListener = listener
        listener = nil
        currentConnections = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        currentListener?.cancel()
        currentConnections.forEach { $0.cancel() }
    }

    private func removeConnection(_ id: UUID) {
        lock.lock()
        connections.removeValue(forKey: id)
        lock.unlock()
    }

    private static let successHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>Lighthouse</title></head><body><p>Google Drive 연결이 완료되었습니다. Lighthouse로 돌아가세요.</p></body></html>
    """

    private static let failureHTML = """
    <!doctype html><html><head><meta charset="utf-8"><title>Lighthouse</title></head><body><p>Google Drive 연결을 완료하지 못했습니다. Lighthouse에서 다시 시도해 주세요.</p></body></html>
    """
}
