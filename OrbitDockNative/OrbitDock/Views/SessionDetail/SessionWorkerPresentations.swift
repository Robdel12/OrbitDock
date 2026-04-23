import Foundation
import SwiftUI

struct SessionWorkerRosterPresentation {
  struct Worker: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let statusLabel: String
    let statusColor: Color
    let isActive: Bool
    let iconName: String
  }

  let title: String
  let summary: String
  let detailPrompt: String
  let workers: [Worker]
}

struct SessionWorkerDetailPresentation {
  struct DetailLine: Identifiable {
    let id: String
    let label: String
    let value: String
  }

  struct ConversationEvent: Identifiable {
    let id: String
    let iconName: String
    let title: String
    let summary: String
    let timestampLabel: String?
    let statusLabel: String
    let statusColor: Color
  }

  struct ToolActivity: Identifiable {
    let id: String
    let iconName: String
    let toolName: String
    let summary: String
    let statusLabel: String
    let statusColor: Color
  }

  struct RelatedWorker: Identifiable {
    let id: String
    let title: String
    let relationshipLabel: String
    let statusLabel: String
    let statusColor: Color
  }

  struct ThreadEntry: Identifiable {
    let id: String
    let iconName: String
    let title: String
    let body: String
    let timestampLabel: String?
    let tint: Color
  }

  struct Capability: Identifiable {
    let id: String
    let label: String
    let value: String
    let color: Color
  }

  let id: String
  let title: String
  let subtitle: String?
  let statusLabel: String
  let statusColor: Color
  let iconName: String
  let isActive: Bool
  let statusNarrative: String
  let assignmentPreview: String?
  let reportPreview: String?
  let detailLines: [DetailLine]
  let tools: [ToolActivity]
  let threadEntries: [ThreadEntry]
  let conversationEvents: [ConversationEvent]
  let relatedWorkers: [RelatedWorker]
  let latestConversationEventID: String?
  let capabilities: [Capability]
  let limitations: [String]
  let conversationRows: [ServerConversationRowEntry]
  let transcriptStatusLabel: String
  let canSendMessage: Bool
  let messageModeLabel: String?
}
