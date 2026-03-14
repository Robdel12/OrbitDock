import Foundation

/// Per-window store that owns the session list and inline side effects.
///
/// Replaces RootShellStore, RootShellRuntime, RootShellReducer,
/// RootShellEffectsCoordinator, RootSelectionBridge, and SessionRegistry.
///
/// Each window creates its own AppStore. The underlying EventStream
/// (one WS connection per endpoint) is shared via ServerRuntimeRegistry.
@Observable
@MainActor
final class AppStore {
  // MARK: - Published State

  private(set) var counts = RootShellCounts()
  private(set) var endpointHealthRecords: [RootShellEndpointHealth] = []
  private(set) var orderedRecordsStorage: [RootSessionNode] = []
  private(set) var missionControlRecordsStorage: [RootSessionNode] = []
  private(set) var recentRecordsStorage: [RootSessionNode] = []
  private(set) var selectedEndpointFilter: RootShellEndpointFilter = .all

  // MARK: - Internal State

  @ObservationIgnored private var recordsByScopedID: [String: RootSessionNode] = [:]
  @ObservationIgnored private var knownMissionControlSessions: [String: RootSessionNode] = [:]

  // MARK: - Dependencies

  @ObservationIgnored private let runtimeRegistry: ServerRuntimeRegistry
  @ObservationIgnored private let attentionService: AttentionService
  @ObservationIgnored private let notificationManager: NotificationManager
  @ObservationIgnored private let toastManager: ToastManager

  // MARK: - Per-window context

  @ObservationIgnored weak var router: AppRouter?

  // MARK: - Tasks

  @ObservationIgnored private var observationTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var selectionBridgeTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var pendingFlushTask: Task<Void, Never>?
  @ObservationIgnored private var pendingEvents: [(endpointId: UUID, event: ServerEvent)] = []

  init(
    runtimeRegistry: ServerRuntimeRegistry,
    attentionService: AttentionService,
    notificationManager: NotificationManager,
    toastManager: ToastManager
  ) {
    self.runtimeRegistry = runtimeRegistry
    self.attentionService = attentionService
    self.notificationManager = notificationManager
    self.toastManager = toastManager
  }

  deinit {
    pendingFlushTask?.cancel()
    for task in observationTasks.values { task.cancel() }
    for task in selectionBridgeTasks.values { task.cancel() }
  }

  // MARK: - Testing / Preview

  func seed(records: [RootSessionNode]) {
    for record in records {
      recordsByScopedID[record.scopedID] = record
    }
    refreshDerivedState()
    syncPublishedState()
  }

  // MARK: - Lifecycle

  func start() {
    runtimeGraphDidChange()
  }

  func runtimeGraphDidChange() {
    let currentEndpointIds = Set(runtimeRegistry.runtimes.map(\.endpoint.id))

    // Tear down removed endpoints
    for endpointId in observationTasks.keys where !currentEndpointIds.contains(endpointId) {
      observationTasks[endpointId]?.cancel()
      observationTasks.removeValue(forKey: endpointId)
    }
    for endpointId in selectionBridgeTasks.keys where !currentEndpointIds.contains(endpointId) {
      selectionBridgeTasks[endpointId]?.cancel()
      selectionBridgeTasks.removeValue(forKey: endpointId)
    }

    // Start new endpoints
    for runtime in runtimeRegistry.runtimes {
      let endpointId = runtime.endpoint.id

      if observationTasks[endpointId] == nil {
        bootstrapFromSnapshot(runtime)
        observeEvents(from: runtime)
      }

      if selectionBridgeTasks[endpointId] == nil {
        observeSelectionRequests(from: runtime)
      }
    }
  }

  func setCurrentSelection(_ sessionRef: SessionRef?) {
    toastManager.currentSessionId = sessionRef?.scopedID
  }

  func setEndpointFilter(_ filter: RootShellEndpointFilter) {
    guard selectedEndpointFilter != filter else { return }
    selectedEndpointFilter = filter
  }

  // MARK: - Queries

  var endpointHealth: [RootShellEndpointHealth] {
    endpointHealthRecords
  }

  func sessionRef(for scopedID: ScopedSessionID) -> SessionRef? {
    recordsByScopedID[scopedID.scopedID]?.sessionRef
  }

  func sessionRef(for scopedID: String) -> SessionRef? {
    guard let scopedID = ScopedSessionID(scopedID: scopedID) else { return nil }
    return sessionRef(for: scopedID)
  }

  func record(for scopedID: String) -> RootSessionNode? {
    recordsByScopedID[scopedID]
  }

  func records(filter: RootShellEndpointFilter? = nil) -> [RootSessionNode] {
    let filter = filter ?? selectedEndpointFilter
    switch filter {
      case .all:
        return orderedRecordsStorage
      case let .endpoint(endpointId):
        return orderedRecordsStorage.filter { $0.sessionRef.endpointId == endpointId }
    }
  }

  func missionControlRecords() -> [RootSessionNode] {
    missionControlRecordsStorage
  }

  func recentRecords(limit: Int? = nil) -> [RootSessionNode] {
    if let limit {
      return Array(recentRecordsStorage.prefix(limit))
    }
    return recentRecordsStorage
  }

  // MARK: - Bootstrap

  private func bootstrapFromSnapshot(_ runtime: ServerRuntime) {
    let eventStream = runtime.eventStream
    guard eventStream.hasReceivedInitialSessionsList else { return }

    let endpointId = runtime.endpoint.id
    let endpointName = runtime.endpoint.name
    let connectionStatus = runtimeRegistry.displayConnectionStatus(for: endpointId)

    applySessionsList(
      endpointId: endpointId,
      endpointName: endpointName,
      connectionStatus: connectionStatus,
      sessions: eventStream.latestSessionListItems
    )
  }

  // MARK: - Event Observation

  private func observeEvents(from runtime: ServerRuntime) {
    let endpointId = runtime.endpoint.id

    observationTasks[endpointId] = Task { [weak self] in
      for await event in runtime.eventStream.rootEvents {
        guard !Task.isCancelled else { break }
        guard let self else { break }
        self.enqueueEvent(endpointId: endpointId, event: event)
      }
    }
  }

  private func observeSelectionRequests(from runtime: ServerRuntime) {
    let endpointId = runtime.endpoint.id

    selectionBridgeTasks[endpointId] = Task { [weak self] in
      for await ref in runtime.sessionStore.selectionRequests {
        guard !Task.isCancelled else { break }
        self?.router?.selectSession(ref)
      }
    }
  }

  // MARK: - Event Processing

  private func enqueueEvent(endpointId: UUID, event: ServerEvent) {
    pendingEvents.append((endpointId: endpointId, event: event))
    scheduleFlush()
  }

  private func scheduleFlush() {
    guard pendingFlushTask == nil else { return }

    pendingFlushTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await Task.yield()
      self.flush()
    }
  }

  private func flush() {
    defer { pendingFlushTask = nil }
    let events = pendingEvents
    pendingEvents.removeAll(keepingCapacity: true)
    guard !events.isEmpty else { return }

    var changed = false
    for (endpointId, event) in events {
      let runtime = runtimeRegistry.runtimesByEndpointId[endpointId]
      let endpointName = runtime?.endpoint.name
      let connectionStatus = runtimeRegistry.displayConnectionStatus(for: endpointId)

      if applyEvent(event, endpointId: endpointId, endpointName: endpointName, connectionStatus: connectionStatus) {
        changed = true
      }
    }

    guard changed else { return }
    refreshDerivedState()
    syncPublishedState()
    applySideEffects()
  }

  private func applyEvent(
    _ event: ServerEvent,
    endpointId: UUID,
    endpointName: String?,
    connectionStatus: ConnectionStatus
  ) -> Bool {
    switch event {
      case let .sessionsList(sessions):
        return applySessionsList(
          endpointId: endpointId,
          endpointName: endpointName,
          connectionStatus: connectionStatus,
          sessions: sessions
        )

      case let .sessionCreated(session),
        let .sessionListItemUpdated(session):
        let record = RootSessionNode(
          session: session,
          endpointId: endpointId,
          endpointName: endpointName,
          connectionStatus: connectionStatus
        )
        if recordsByScopedID[record.scopedID] != record {
          recordsByScopedID[record.scopedID] = record
          return true
        }
        return false

      case let .sessionListItemRemoved(sessionId):
        let scopedID = ScopedSessionID(endpointId: endpointId, sessionId: sessionId).scopedID
        return recordsByScopedID.removeValue(forKey: scopedID) != nil

      case let .sessionEnded(sessionId, reason):
        let scopedID = ScopedSessionID(endpointId: endpointId, sessionId: sessionId).scopedID
        guard let record = recordsByScopedID[scopedID] else { return false }
        let endedRecord = record.ended(reason: reason)
        guard endedRecord != record else { return false }
        recordsByScopedID[scopedID] = endedRecord
        return true

      case let .connectionStatusChanged(status):
        var changed = false
        for (scopedID, record) in recordsByScopedID where record.sessionRef.endpointId == endpointId {
          let nextRecord = record.withConnectionStatus(status, endpointName: endpointName)
          if nextRecord != record {
            recordsByScopedID[scopedID] = nextRecord
            changed = true
          }
        }
        return changed

      default:
        return false
    }
  }

  @discardableResult
  private func applySessionsList(
    endpointId: UUID,
    endpointName: String?,
    connectionStatus: ConnectionStatus,
    sessions: [ServerSessionListItem]
  ) -> Bool {
    let prefix = "\(endpointId.uuidString)\(SessionRef.delimiter)"
    let scopedIDs = Set(sessions.map { ScopedSessionID(endpointId: endpointId, sessionId: $0.id).scopedID })

    // Remove sessions from this endpoint that are no longer in the list
    let retainedRecords = recordsByScopedID.filter { key, _ in
      guard key.hasPrefix(prefix) else { return true }
      return scopedIDs.contains(key)
    }
    var nextRecords = retainedRecords

    for session in sessions {
      let record = RootSessionNode(
        session: session,
        endpointId: endpointId,
        endpointName: endpointName,
        connectionStatus: connectionStatus
      )
      nextRecords[record.scopedID] = record
    }

    guard nextRecords != recordsByScopedID else { return false }
    recordsByScopedID = nextRecords
    refreshDerivedState()
    syncPublishedState()
    return true
  }

  // MARK: - Derived State

  @ObservationIgnored private var derivedOrderedRecords: [RootSessionNode] = []
  @ObservationIgnored private var derivedMissionControlRecords: [RootSessionNode] = []
  @ObservationIgnored private var derivedRecentRecords: [RootSessionNode] = []
  @ObservationIgnored private var derivedCounts = RootShellCounts()
  @ObservationIgnored private var derivedEndpointHealthByID: [UUID: RootShellEndpointHealth] = [:]
  @ObservationIgnored private var derivedOrderedEndpointIDs: [UUID] = []

  private func refreshDerivedState() {
    let records = Array(recordsByScopedID.values)
    derivedOrderedRecords = records.sorted(by: Self.compareRecords)
    derivedMissionControlRecords = derivedOrderedRecords.filter(\.showsInMissionControl)
    derivedRecentRecords = records
      .filter { !$0.showsInMissionControl }
      .sorted { Self.recentDate(for: $0) > Self.recentDate(for: $1) }

    derivedCounts = records.reduce(into: RootShellCounts()) { counts, record in
      counts.total += 1
      guard record.isActive else { return }
      counts.active += 1
      if record.listStatus == .working {
        counts.working += 1
      }
      if record.needsAttention {
        counts.attention += 1
      }
      if record.isReady {
        counts.ready += 1
      }
    }

    let grouped = Dictionary(grouping: records, by: { $0.sessionRef.endpointId })
    derivedEndpointHealthByID = grouped.reduce(into: [:]) { result, entry in
      let endpointId = entry.key
      let endpointRecords = entry.value
      let counts = endpointRecords.reduce(into: RootShellCounts()) { counts, record in
        counts.total += 1
        guard record.isActive else { return }
        counts.active += 1
        if record.listStatus == .working { counts.working += 1 }
        if record.needsAttention { counts.attention += 1 }
        if record.isReady { counts.ready += 1 }
      }
      let sample = endpointRecords.first
      result[endpointId] = RootShellEndpointHealth(
        endpointId: endpointId,
        endpointName: sample?.endpointName ?? "Server",
        connectionStatus: sample?.endpointConnectionStatus ?? .disconnected,
        counts: counts
      )
    }

    derivedOrderedEndpointIDs = derivedEndpointHealthByID.values
      .sorted {
        if $0.endpointName != $1.endpointName {
          return $0.endpointName.localizedCaseInsensitiveCompare($1.endpointName) == .orderedAscending
        }
        return $0.endpointId.uuidString < $1.endpointId.uuidString
      }
      .map(\.endpointId)
  }

  private func syncPublishedState() {
    counts = derivedCounts
    endpointHealthRecords = derivedOrderedEndpointIDs.compactMap { derivedEndpointHealthByID[$0] }
    orderedRecordsStorage = derivedOrderedRecords
    missionControlRecordsStorage = derivedMissionControlRecords
    recentRecordsStorage = derivedRecentRecords
  }

  // MARK: - Side Effects (inline, per-window)

  private func applySideEffects() {
    let currentMissionControl = Dictionary(
      missionControlRecordsStorage.map { ($0.scopedID, $0) },
      uniquingKeysWith: { _, new in new }
    )

    // Find removed sessions
    for scopedID in knownMissionControlSessions.keys where currentMissionControl[scopedID] == nil {
      notificationManager.removeSessionTracking(for: scopedID)
      toastManager.removeSession(scopedID)
      attentionService.remove(sessionId: scopedID)
    }

    // Process upserted sessions
    for (scopedID, session) in currentMissionControl {
      let previous = knownMissionControlSessions[scopedID]
      notificationManager.updateSessionWorkStatus(session: session)
      toastManager.applySessionTransition(current: session, previous: previous)
      attentionService.apply(session: session)

      if session.needsAttention && previous?.needsAttention != true {
        notificationManager.notifyNeedsAttention(session: session)
      } else if !session.needsAttention, previous?.needsAttention == true {
        notificationManager.resetNotificationState(for: scopedID)
      }
    }

    // Also clean up sessions that left mission control
    for (scopedID, _) in knownMissionControlSessions where currentMissionControl[scopedID] == nil {
      notificationManager.removeSessionTracking(for: scopedID)
      toastManager.removeSession(scopedID)
      attentionService.remove(sessionId: scopedID)
    }

    knownMissionControlSessions = currentMissionControl
  }

  // MARK: - Sorting

  nonisolated private static func compareRecords(_ lhs: RootSessionNode, _ rhs: RootSessionNode) -> Bool {
    if lhs.isActive != rhs.isActive {
      return lhs.isActive && !rhs.isActive
    }

    let lhsDate = lhs.lastActivityAt ?? lhs.startedAt ?? .distantPast
    let rhsDate = rhs.lastActivityAt ?? rhs.startedAt ?? .distantPast
    if lhsDate != rhsDate {
      return lhsDate > rhsDate
    }

    if lhs.titleSortKey != rhs.titleSortKey {
      return lhs.titleSortKey < rhs.titleSortKey
    }

    if lhs.endpointName != rhs.endpointName {
      return (lhs.endpointName ?? "") < (rhs.endpointName ?? "")
    }

    if lhs.sessionRef.endpointId != rhs.sessionRef.endpointId {
      return lhs.sessionRef.endpointId.uuidString < rhs.sessionRef.endpointId.uuidString
    }
    return lhs.sessionRef.sessionId < rhs.sessionRef.sessionId
  }

  nonisolated private static func recentDate(for record: RootSessionNode) -> Date {
    record.lastActivityAt ?? record.endedAt ?? record.startedAt ?? .distantPast
  }

  nonisolated private static func isRootSafe(_ event: ServerEvent) -> Bool {
    switch event {
      case .sessionsList,
        .sessionCreated,
        .sessionListItemUpdated,
        .sessionListItemRemoved,
        .sessionEnded,
        .connectionStatusChanged:
        true
      default:
        false
    }
  }
}
