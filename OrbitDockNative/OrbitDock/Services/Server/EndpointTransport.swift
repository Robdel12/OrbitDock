import Foundation

protocol ServerConnectionTransport: Sendable {
  func connect(
    to url: URL,
    generation: UInt64,
    onEvent: @escaping EndpointTransport.EventHandler
  ) async
  func disconnect() async
  func activateKeepAlive(for generation: UInt64) async
  func probe(generation: UInt64) async throws
  func execute(_ request: URLRequest) async throws -> HTTPResponse
  func sendText(_ text: String) async
}

actor EndpointTransport: ServerConnectionTransport {
  struct DisconnectFailure: Sendable {
    let transportError: HTTPTransportError
    let urlErrorCode: URLError.Code?
  }

  enum Event: Sendable {
    case textFrame(String, generation: UInt64)
    case binaryFrame(Data, generation: UInt64)
    case disconnected(generation: UInt64, failure: DisconnectFailure?)
  }

  typealias EventHandler = @Sendable (Event) async -> Void

  private let authToken: String?
  private let wsSession: URLSession
  private let httpSession: URLSession
  private var webSocket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var keepAliveTask: Task<Void, Never>?
  private var currentGeneration: UInt64?
  private var eventHandler: EventHandler?

  private static let maxInboundBytes = 8 * 1_024 * 1_024
  private static let keepAliveInterval: TimeInterval = 30

  init(authToken: String?) {
    self.authToken = authToken

    let wsConfig = URLSessionConfiguration.default
    wsConfig.timeoutIntervalForRequest = 10
    wsConfig.timeoutIntervalForResource = 0
    self.wsSession = URLSession(configuration: wsConfig)

    let httpConfig = URLSessionConfiguration.default
    httpConfig.timeoutIntervalForRequest = 10
    httpConfig.timeoutIntervalForResource = 60
    httpConfig.httpMaximumConnectionsPerHost = 2
    httpConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
    httpConfig.urlCache = nil
    self.httpSession = URLSession(configuration: httpConfig)
  }

  func connect(
    to url: URL,
    generation: UInt64,
    onEvent: @escaping EventHandler
  ) async {
    disconnectCurrentConnection()

    currentGeneration = generation
    eventHandler = onEvent

    var request = URLRequest(url: url)
    if let authToken, !authToken.isEmpty {
      request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
    request.setValue("0.4.0", forHTTPHeaderField: "X-OrbitDock-Client-Version")
    request.setValue(
      "server_authoritative_session_v1",
      forHTTPHeaderField: "X-OrbitDock-Client-Compatibility"
    )

    let socket = wsSession.webSocketTask(with: request)
    socket.maximumMessageSize = Self.maxInboundBytes
    webSocket = socket
    socket.resume()

    receiveTask = Task {
      await receiveLoop(on: socket, generation: generation)
    }
  }

  func disconnect() async {
    disconnectCurrentConnection()
  }

  func activateKeepAlive(for generation: UInt64) async {
    guard currentGeneration == generation else { return }

    keepAliveTask?.cancel()
    keepAliveTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(Self.keepAliveInterval))
        guard !Task.isCancelled else { return }

        do {
          try await ping(generation: generation)
        } catch {
          guard !Task.isCancelled else { return }
          await emitDisconnectIfCurrent(
            generation: generation,
            failure: makeDisconnectFailure(from: error)
          )
          return
        }
      }
    }
  }

  func probe(generation: UInt64) async throws {
    try await ping(generation: generation)
  }

  func execute(_ request: URLRequest) async throws -> HTTPResponse {
    let result: (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
      let task = httpSession.dataTask(with: request) { data, response, error in
        if let error {
          continuation.resume(throwing: HTTPTransportError(error: error))
        } else if let data, let response {
          continuation.resume(returning: (data, response))
        } else {
          continuation.resume(throwing: HTTPTransportError.invalidResponse)
        }
      }
      task.resume()
    }

    return try HTTPResponse(data: result.0, response: result.1)
  }

  func sendText(_ text: String) async {
    guard let webSocket else { return }
    webSocket.send(.string(text)) { _ in }
  }

  private func receiveLoop(on socket: URLSessionWebSocketTask, generation: UInt64) async {
    while !Task.isCancelled {
      guard currentGeneration == generation else { return }

      do {
        let message = try await socket.receive()
        guard !Task.isCancelled, currentGeneration == generation else { return }

        switch message {
          case let .string(text):
            await emit(.textFrame(text, generation: generation))
          case let .data(data):
            await emit(.binaryFrame(data, generation: generation))
          @unknown default:
            break
        }
      } catch {
        guard !Task.isCancelled else { return }
        await emitDisconnectIfCurrent(
          generation: generation,
          failure: makeDisconnectFailure(from: error)
        )
        return
      }
    }
  }

  private func ping(generation: UInt64) async throws {
    guard currentGeneration == generation, let socket = webSocket else {
      throw HTTPTransportError.serverUnreachable
    }

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let resumeLock = NSLock()
      var didResume = false

      let resumeOnce: (Result<Void, Error>) -> Void = { result in
        resumeLock.lock()
        defer { resumeLock.unlock() }

        guard !didResume else { return }
        didResume = true

        switch result {
          case .success:
            continuation.resume()
          case let .failure(error):
            continuation.resume(throwing: error)
        }
      }

      socket.sendPing { error in
        if let error {
          resumeOnce(.failure(error))
        } else {
          resumeOnce(.success(()))
        }
      }
    }
  }

  private func emitDisconnectIfCurrent(generation: UInt64, failure: DisconnectFailure?) async {
    guard currentGeneration == generation else { return }
    let handler = eventHandler
    disconnectCurrentConnection()
    guard let handler else { return }
    await handler(.disconnected(generation: generation, failure: failure))
  }

  private func emit(_ event: Event) async {
    guard let eventHandler else { return }
    await eventHandler(event)
  }

  private func disconnectCurrentConnection() {
    currentGeneration = nil
    keepAliveTask?.cancel()
    keepAliveTask = nil
    receiveTask?.cancel()
    receiveTask = nil
    webSocket?.cancel(with: .goingAway, reason: nil)
    webSocket = nil
    eventHandler = nil
  }

  private func makeDisconnectFailure(from error: Error) -> DisconnectFailure {
    let transportError = (error as? HTTPTransportError) ?? HTTPTransportError(error: error)
    return DisconnectFailure(
      transportError: transportError,
      urlErrorCode: urlErrorCode(from: error)
    )
  }

  private func urlErrorCode(from error: Error) -> URLError.Code? {
    if let urlError = error as? URLError {
      return urlError.code
    }

    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return nil }
    return URLError.Code(rawValue: nsError.code)
  }
}
