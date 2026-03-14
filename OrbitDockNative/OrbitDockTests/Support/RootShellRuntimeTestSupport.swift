import Foundation
import Testing
@testable import OrbitDock

enum RootShellRuntimeTestSupport {
  @MainActor
  static func firstUpdate(
    from runtime: RootShellRuntime,
    after action: @escaping @MainActor () -> Void,
    timeout: Duration = .seconds(2)
  ) async throws -> RootShellRuntimeUpdate {
    let updateTask = Task { @MainActor in
      for await update in runtime.updates {
        return update
      }
      throw AwaitFailure.endedWithoutUpdate
    }

    action()

    do {
      return try await race(updateTask: updateTask, timeout: timeout)
    } catch {
      updateTask.cancel()
      throw error
    }
  }

  private static func race(
    updateTask: Task<RootShellRuntimeUpdate, Error>,
    timeout: Duration
  ) async throws -> RootShellRuntimeUpdate {
    try await withThrowingTaskGroup(of: RootShellRuntimeUpdate.self) { group in
      group.addTask {
        try await updateTask.value
      }
      group.addTask {
        try await ContinuousClock().sleep(for: timeout)
        throw AwaitFailure.timedOut(timeout)
      }

      defer {
        group.cancelAll()
        updateTask.cancel()
      }

      let update = try await group.next()
      return try #require(update)
    }
  }

  enum AwaitFailure: Error, CustomStringConvertible {
    case timedOut(Duration)
    case endedWithoutUpdate

    var description: String {
      switch self {
      case .timedOut(let timeout):
        "Timed out waiting for root-shell update after \(timeout.components.seconds) seconds."
      case .endedWithoutUpdate:
        "Root-shell update stream ended before emitting an update."
      }
    }
  }
}
