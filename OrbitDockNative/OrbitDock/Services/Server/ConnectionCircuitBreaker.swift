import Foundation

/// Circuit breaker for WebSocket connection attempts.
///
/// States: closed → open(until:) → halfOpen
/// Prevents connection flood when server is unreachable.
@MainActor
final class ConnectionCircuitBreaker {
  enum State: Equatable {
    case closed
    case open(until: Date)
    case halfOpen
  }

  private(set) var state: State = .closed
  private var consecutiveFailures = 0

  let failureThreshold: Int
  let initialCooldown: TimeInterval
  let maxCooldown: TimeInterval
  let multiplier: Double

  init(
    failureThreshold: Int = 3,
    initialCooldown: TimeInterval = 5,
    maxCooldown: TimeInterval = 60,
    multiplier: Double = 2
  ) {
    self.failureThreshold = failureThreshold
    self.initialCooldown = initialCooldown
    self.maxCooldown = maxCooldown
    self.multiplier = multiplier
  }

  /// Local server defaults: fast cooldown, shorter max.
  static func local() -> ConnectionCircuitBreaker {
    ConnectionCircuitBreaker(failureThreshold: 3, initialCooldown: 5, maxCooldown: 60, multiplier: 2)
  }

  /// Remote server defaults: slower cooldown, longer max.
  static func remote() -> ConnectionCircuitBreaker {
    ConnectionCircuitBreaker(failureThreshold: 3, initialCooldown: 10, maxCooldown: 120, multiplier: 2)
  }

  var shouldAllow: Bool {
    switch state {
      case .closed:
        return true
      case let .open(until):
        if Date() >= until {
          state = .halfOpen
          return true
        }
        return false
      case .halfOpen:
        return true
    }
  }

  /// Time remaining before next attempt is allowed. Returns nil if attempts are allowed now.
  var cooldownRemaining: TimeInterval? {
    guard case let .open(until) = state else { return nil }
    let remaining = until.timeIntervalSinceNow
    return remaining > 0 ? remaining : nil
  }

  func recordFailure() {
    consecutiveFailures += 1
    guard consecutiveFailures >= failureThreshold else { return }
    let exponent = Double(consecutiveFailures - failureThreshold)
    let cooldown = min(initialCooldown * pow(multiplier, exponent), maxCooldown)
    state = .open(until: Date().addingTimeInterval(cooldown))
  }

  func recordSuccess() {
    consecutiveFailures = 0
    state = .closed
  }

  func reset() {
    consecutiveFailures = 0
    state = .closed
  }
}
