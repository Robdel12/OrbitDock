import CoreGraphics
import Foundation

struct DirectSessionComposerPendingState: Equatable {
  var isExpanded = true
  var promptIndex = 0
  var permissionGrantScope: ServerPermissionGrantScope = .turn
  var answers: [String: [String]] = [:]
  var drafts: [String: String] = [:]
  var showsDenyReason = false
  var denyReason = ""
  var measuredContentHeight: CGFloat = 0
  var isHovering = false
  var lastHapticApprovalIdentity = ""

  var hasDenyReason: Bool {
    !denyReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  mutating func resetForNewRequest() {
    isExpanded = true
    promptIndex = 0
    permissionGrantScope = .turn
    answers = [:]
    drafts = [:]
    showsDenyReason = false
    denyReason = ""
    measuredContentHeight = 0
  }

  mutating func setMeasuredContentHeight(_ value: CGFloat) {
    measuredContentHeight = max(0, value)
  }

  mutating func cancelDenyReason() {
    showsDenyReason = false
    denyReason = ""
  }
}
