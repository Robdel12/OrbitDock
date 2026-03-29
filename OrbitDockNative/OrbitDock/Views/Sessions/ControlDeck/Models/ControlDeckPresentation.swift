import Foundation

/// The deck's active interaction mode, derived from session state.
enum ControlDeckMode: Equatable, Sendable {
  /// Normal compose — session accepts new turns
  case compose
  /// Steer — session is working, user can send steering feedback
  case steer
  /// Approval — session is waiting for user to respond to a pending approval
  case approval
  /// Disabled — session ended or not accepting input
  case disabled
}

struct ControlDeckPresentation: Equatable, Sendable {
  let mode: ControlDeckMode
  let controlModeLabel: String
  let lifecycleLabel: String
  let lifecycleTint: String
  let acceptsUserInput: Bool
  let supportsImages: Bool
  let headerSubtitle: String
  let statusModules: [ControlDeckStatusModuleItem]
  let placeholder: String
  let sendTint: String
}

struct ControlDeckStatusModuleItem: Identifiable, Equatable, Sendable {
  let id: ControlDeckStatusModule
  let label: String
  let icon: String
  let tintName: String
  let selectedValue: String?
  let reviewerValue: String?
  let interaction: Interaction

  enum Interaction: Equatable, Sendable {
    /// Read-only display, no tap action
    case readOnly
    /// Tappable — opens a picker with the given options. Current value is `label`.
    case picker(options: [Option])
  }

  struct Option: Identifiable, Equatable, Sendable {
    let value: String
    let label: String

    var id: String {
      value
    }
  }
}
