import Foundation

typealias SessionSurfaceSet = Set<ServerSessionSurface>
typealias SessionInvalidationSet = Set<ServerSessionInvalidation>

enum ServerSessionInvalidation: String, Hashable, Sendable {
  case conversation
  case detail
  case review
  case capabilities
  case skills
  case mcp
}

@MainActor
final class ServerSessionTransport {
  enum Event: Sendable {
    case invalidated(SessionInvalidationSet)
    case conversationRowsChanged(ConversationRowDelta)
  }

  struct ConversationRowDelta: Sendable {
    let upserted: [ServerConversationRowEntry]
    let removedIds: [String]
  }

  let sessionId: String
  @ObservationIgnored let endpointRuntime: ServerEndpointRuntime

  @ObservationIgnored private var eventContinuations: [UUID: AsyncStream<Event>.Continuation] = [:]
  @ObservationIgnored private var surfaceSubscriptionCounts: [ServerSessionSurface: Int] = [:]
  @ObservationIgnored private var lastRevision: UInt64?

  var latestRevision: UInt64? {
    lastRevision
  }

  init(sessionId: String, endpointRuntime: ServerEndpointRuntime) {
    self.sessionId = sessionId
    self.endpointRuntime = endpointRuntime
  }

  func stopProcessingEvents() {
    unsubscribe()
    eventContinuations.values.forEach { $0.finish() }
    eventContinuations.removeAll()
  }

  func events() -> (stream: AsyncStream<Event>, id: UUID) {
    let id = UUID()
    let stream = AsyncStream<Event> { continuation in
      eventContinuations[id] = continuation
      continuation.onTermination = { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.removeEventListener(id: id)
        }
      }
    }
    return (stream, id)
  }

  func removeEventListener(id: UUID) {
    eventContinuations[id] = nil
  }

  func recordRevision(_ revision: UInt64?) {
    guard let revision else { return }
    lastRevision = max(lastRevision ?? revision, revision)
  }

  func subscribe(surfaces: SessionSurfaceSet) {
    guard !surfaces.isEmpty, !sessionId.isEmpty else { return }

    var newSurfaces: SessionSurfaceSet = []
    for surface in surfaces {
      let currentCount = surfaceSubscriptionCounts[surface, default: 0]
      surfaceSubscriptionCounts[surface] = currentCount + 1
      if currentCount == 0 {
        newSurfaces.insert(surface)
      }
    }
    guard !newSurfaces.isEmpty else { return }
    guard endpointRuntime.connection.connectionStatus == .connected else { return }

    for surface in newSurfaces {
      endpointRuntime.connection.subscribeSessionSurface(
        sessionId,
        surface: surface,
        sinceRevision: lastRevision
      )
    }
  }

  func unsubscribe(surfaces: SessionSurfaceSet? = nil) {
    let targetSurfaces = surfaces ?? subscribedSurfaces
    guard !targetSurfaces.isEmpty else { return }

    var removedSurfaces: SessionSurfaceSet = []
    for surface in targetSurfaces {
      let currentCount = surfaceSubscriptionCounts[surface, default: 0]
      guard currentCount > 0 else { continue }
      if currentCount == 1 {
        surfaceSubscriptionCounts.removeValue(forKey: surface)
        removedSurfaces.insert(surface)
      } else {
        surfaceSubscriptionCounts[surface] = currentCount - 1
      }
    }

    for surface in removedSurfaces {
      endpointRuntime.connection.unsubscribeSessionSurface(sessionId, surface: surface)
    }

    if subscribedSurfaces.isEmpty {
      lastRevision = nil
      endpointRuntime.removeSession(sessionId)
    }
  }

  func handleEvent(_ event: ServerEvent) {
    switch event {
      case let .sessionSurfaceInvalidated(_, surface, revision):
        recordRevision(revision)
        if let invalidation = Self.invalidation(for: surface) {
          invalidate([invalidation])
        }

      case .skillsUpdateAvailable:
        invalidate([.skills])

      case .mcpStartupUpdate, .mcpStartupComplete:
        invalidate([.mcp])

      case .claudeCapabilities:
        invalidate([.capabilities])

      case let .conversationRowsChanged(_, upserted, removedRowIds, _):
        emitConversationRows(.init(upserted: upserted, removedIds: removedRowIds))

      case let .revision(_, revision):
        recordRevision(revision)

      case let .sessionForked(_, newSessionId, _):
        endpointRuntime.requestSelection(
          SessionRef(endpointId: endpointRuntime.endpointId, sessionId: newSessionId)
        )

      default:
        break
    }
  }

  func handleError(_ code: String, _ message: String) {
    netLog(.error, cat: .store, "Server error", sid: sessionId, data: ["code": code, "message": message])

    switch code {
      case "lagged", "replay_oversized":
        invalidate([.conversation, .detail, .review, .capabilities, .skills, .mcp])
        return
      default:
        break
    }

    if code == "codex_auth_error" {
      endpointRuntime.applyCodexAuthError(message)
      return
    }

    endpointRuntime.lastServerError = (code: code, message: message)
  }

  func handleConnectionStatusChanged(_ status: ConnectionStatus) {
    guard status == .connected, !subscribedSurfaces.isEmpty else { return }
    for surface in subscribedSurfaces {
      endpointRuntime.connection.subscribeSessionSurface(
        sessionId,
        surface: surface,
        sinceRevision: lastRevision
      )
    }
  }

  func emitConversationRows(_ delta: ConversationRowDelta) {
    notifyEvent(.conversationRowsChanged(delta))
  }

  func invalidate(_ targets: SessionInvalidationSet) {
    guard !targets.isEmpty else { return }
    notifyEvent(.invalidated(targets))
  }

  private var subscribedSurfaces: SessionSurfaceSet {
    Set(surfaceSubscriptionCounts.keys)
  }

  private static func invalidation(for surface: ServerSessionSurface) -> ServerSessionInvalidation? {
    switch surface {
      case .conversation:
        .conversation
      case .detail, .composer:
        .detail
      case .review:
        .review
      case .capabilities:
        .capabilities
    }
  }

  private func notifyEvent(_ event: Event) {
    eventContinuations.values.forEach { $0.yield(event) }
  }
}

extension ServerSessionTransport.Event {
  func invalidates(_ target: ServerSessionInvalidation) -> Bool {
    guard case let .invalidated(targets) = self else { return false }
    return targets.contains(target)
  }
}
