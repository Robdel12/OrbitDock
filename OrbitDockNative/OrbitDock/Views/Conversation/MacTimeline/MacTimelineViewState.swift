import Foundation

#if os(macOS)

  struct MacTimelineViewState: Equatable {
    let rows: [MacTimelineRowRecord]
    let isPinnedToBottom: Bool
    let unreadCount: Int
  }

  enum MacTimelineViewStateBuilder {
    @MainActor
    static func build(
      renderStore: ConversationRenderStore,
      messagesByID: [String: TranscriptMessage],
      chatViewMode: ChatViewMode,
      expansionState: ConversationTimelineExpansionState,
      expandedToolIDs: Set<String>,
      loadState: ConversationViewLoadState,
      remainingLoadCount: Int,
      isPinnedToBottom: Bool,
      unreadCount: Int
    ) -> MacTimelineViewState {
      let rows: [MacTimelineRowRecord]
      switch loadState {
        case .loading:
          rows = [
            .utility(
              .init(
                id: "utility:loading",
                kind: .live,
                iconName: "arrow.clockwise",
                eyebrow: "Timeline",
                title: "Loading conversation…",
                subtitle: nil,
                spotlight: nil,
                trailingBadge: "Syncing",
                accentColorName: "working",
                chips: [],
                activityAnchorID: nil,
                isExpanded: false
              )
            )
          ]
        case .empty:
          rows = [
            .utility(
              .init(
                id: "utility:empty",
                kind: .live,
                iconName: "bubble.left.and.text.bubble.right",
                eyebrow: "Timeline",
                title: "No conversation yet",
                subtitle: nil,
                spotlight: nil,
                trailingBadge: nil,
                accentColorName: "reply",
                chips: [],
                activityAnchorID: nil,
                isExpanded: false
              )
            )
          ]
        case .ready:
          var nextRows: [MacTimelineRowRecord] = []
          let semanticRows = ConversationSemanticTimelineBuilder.build(
            renderStore: renderStore,
            messagesByID: messagesByID,
            hasMoreMessages: remainingLoadCount > 0,
            chatViewMode: chatViewMode,
            expansionState: expansionState
          )
          nextRows.append(contentsOf: semanticRows.compactMap { row in
            rowRecord(
              from: row,
              renderStore: renderStore,
              messagesByID: messagesByID,
              expandedToolIDs: expandedToolIDs,
              remainingLoadCount: remainingLoadCount
            )
          })
          rows = nextRows
      }

      return MacTimelineViewState(
        rows: rows,
        isPinnedToBottom: isPinnedToBottom,
        unreadCount: unreadCount
      )
    }
  }

  private extension MacTimelineViewStateBuilder {
    @MainActor
    static func rowRecord(
      from row: TimelineRow,
      renderStore: ConversationRenderStore,
      messagesByID: [String: TranscriptMessage],
      expandedToolIDs: Set<String>,
      remainingLoadCount: Int
    ) -> MacTimelineRowRecord? {
      switch row.kind {
        case .loadMore:
          return .loadMore(.init(id: row.id.rawValue, remainingCount: remainingLoadCount))

        case .message:
          guard case let .message(messageID, showHeader) = row.payload,
                let message = messagesByID[messageID],
                let model = SharedModelBuilders.richMessageModel(
                  from: message,
                  messageID: messageID,
                  isThinkingExpanded: false,
                  showHeader: showHeader
                )
          else {
            return nil
          }
          let streamingState = renderStore.streamingMessages[messageID]
          let text = if let streamingState, !streamingState.content.isEmpty {
            streamingState.content
          } else {
            model.content
          }
          return .message(
            .init(
              id: messageID,
              model: NativeRichMessageRowModel(
                messageID: model.messageID,
                speaker: model.speaker,
                content: text,
                thinking: model.thinking,
                messageType: model.messageType,
                renderMode: model.renderMode,
                timestamp: model.timestamp,
                hasImages: model.hasImages,
                images: model.images,
                isThinkingExpanded: model.isThinkingExpanded,
                showHeader: model.showHeader
              ),
              contentSignature: streamingState.map { Int($0.revision) } ?? message.contentSignature
            )
          )

        case .tool:
          guard case let .tool(messageID) = row.payload,
                let message = messagesByID[messageID]
          else { return nil }
          if expandedToolIDs.contains(messageID) {
            return .expandedTool(
              .init(
                id: messageID,
                model: SharedModelBuilders.expandedToolModel(
                  from: message,
                  messageID: messageID,
                  subagentsByID: subagentsByID(from: renderStore.metadata)
                )
              )
            )
          }
          return .tool(
            .init(
              id: messageID,
              model: SharedModelBuilders.compactToolModel(
                from: message,
                subagentsByID: subagentsByID(from: renderStore.metadata),
                selectedWorkerID: renderStore.metadata.selectedWorkerID
              )
            )
          )

        case .workerEvent:
          guard case let .workerEvent(messageID) = row.payload,
                let message = messagesByID[messageID],
                let model = SharedModelBuilders.workerEventModel(
                  from: message,
                  subagentsByID: subagentsByID(from: renderStore.metadata),
                  selectedWorkerID: renderStore.metadata.selectedWorkerID
                )
          else { return nil }
          return .tool(.init(id: messageID, model: model))

        case .activitySummary:
          guard case let .activitySummary(anchorID, messageIDs, isExpanded) = row.payload else { return nil }
          let messages = messageIDs.compactMap { messagesByID[$0] }
          guard !messages.isEmpty else { return nil }
          let activity = ConversationUtilityRowModels.activitySummary(messages: messages, isExpanded: isExpanded)
          return .utility(
            .init(
              id: row.id.rawValue,
              kind: .activity,
              iconName: activity.iconName,
              eyebrow: "Activity",
              title: activity.titleText,
              subtitle: activity.subtitleText,
              spotlight: isExpanded ? "Showing \(activity.childCount) tool step\(activity.childCount == 1 ? "" : "s")" : nil,
              trailingBadge: activity.badgeText,
              accentColorName: accentColorName(for: activity.accentColorKey),
              chips: [],
              activityAnchorID: anchorID,
              isExpanded: isExpanded
            )
          )

        case .approvalCard:
          guard let approval = approvalRecord(from: renderStore.metadata) else { return nil }
          return .utility(approval)

        case .workerOrchestration:
          let workerModel = ConversationUtilityRowModels.workerOrchestration(
            workerIDs: renderStore.metadata.workerIDs,
            subagentsByID: subagentsByID(from: renderStore.metadata)
          )
          return .utility(
            .init(
              id: row.id.rawValue,
              kind: .workers,
              iconName: "person.3.fill",
              eyebrow: "Workers",
              title: workerModel.titleText,
              subtitle: workerModel.subtitleText,
              spotlight: workerModel.spotlightText,
              trailingBadge: workerModel.workers.first(where: \.isActive)?.statusText
                ?? workerModel.workers.first?.statusText,
              accentColorName: "task",
              chips: workerModel.workers.map { worker in
                .init(
                  id: worker.id,
                  title: worker.title,
                  statusText: worker.statusText,
                  accentColorName: accentColorName(for: worker.statusColorKey),
                  isActive: worker.isActive
                )
              },
              activityAnchorID: nil,
              isExpanded: false
            )
          )

        case .liveIndicator:
          let liveModel = ConversationUtilityRowModels.liveIndicator(
            workStatus: renderStore.metadata.workStatus,
            currentTool: renderStore.metadata.currentTool,
            pendingToolName: renderStore.metadata.pendingToolName
          )
          return .utility(
            .init(
              id: row.id.rawValue,
              kind: .live,
              iconName: liveModel.iconName ?? "bolt.fill",
              eyebrow: liveEyebrow(for: renderStore.metadata.workStatus),
              title: liveModel.primaryText,
              subtitle: liveModel.detailText,
              spotlight: nil,
              trailingBadge: liveBadgeText(for: renderStore.metadata.workStatus),
              accentColorName: liveAccentColorName(for: liveModel),
              chips: [],
              activityAnchorID: nil,
              isExpanded: false
            )
          )

        case .bottomSpacer:
          return .spacer(
            .init(
              id: row.id.rawValue,
              height: ConversationLayout.bottomSpacerHeight
            )
          )
      }
    }

    static func approvalRecord(from metadata: ConversationMetadataSnapshot) -> MacTimelineUtilityRecord? {
      guard let approval = metadata.approval else { return nil }

      let title: String
      let subtitle: String?
      let iconName: String
      let accentColorName: String

      switch approval.type {
        case .question:
          title = "Question pending"
          subtitle = approval.pendingQuestion ?? approval.currentPrompt
          iconName = "questionmark.bubble.fill"
          accentColorName = "reply"
        case .permissions:
          title = "Permissions request"
          subtitle = approval.pendingPermissionDetail ?? approval.currentPrompt
          iconName = "hand.raised.fill"
          accentColorName = "permission"
        case .patch:
          title = "Patch approval needed"
          subtitle = approval.pendingToolName ?? approval.currentPrompt
          iconName = "doc.text.fill"
          accentColorName = "permission"
        case .exec:
          title = "Tool approval needed"
          subtitle = approval.pendingToolName ?? approval.currentPrompt
          iconName = "bolt.shield.fill"
          accentColorName = "permission"
      }

      return .init(
        id: "utility:approval",
        kind: .approval,
        iconName: iconName,
        eyebrow: "Approval",
        title: title,
        subtitle: subtitle,
        spotlight: "Open the pending panel to respond and keep the turn moving.",
        trailingBadge: "Action needed",
        accentColorName: accentColorName,
        chips: [],
        activityAnchorID: nil,
        isExpanded: false
      )
    }

    static func liveAccentColorName(for model: ConversationUtilityRowModels.LiveIndicatorModel) -> String {
      switch model.primaryColorKey {
        case .permission:
          return "permission"
        case .reply:
          return "reply"
        case .working:
          return "working"
        default:
          return "working"
      }
    }

    static func liveEyebrow(for status: Session.WorkStatus) -> String {
      switch status {
        case .working:
          "Live"
        case .waiting:
          "Session"
        case .permission:
          "Blocked"
        case .unknown:
          "Session"
      }
    }

    static func liveBadgeText(for status: Session.WorkStatus) -> String? {
      switch status {
        case .working:
          "Active"
        case .waiting:
          "Ready"
        case .permission:
          "Needs input"
        case .unknown:
          nil
      }
    }

    static func accentColorName(for key: ConversationUtilityRowModels.ColorKey) -> String {
      switch key {
        case .permission:
          "permission"
        case .working:
          "working"
        case .reply:
          "reply"
        case .task:
          "task"
        case .positive:
          "positive"
        case .negative:
          "negative"
        case .caution:
          "caution"
        default:
          "accent"
      }
    }

    static func subagentsByID(from metadata: ConversationMetadataSnapshot) -> [String: ServerSubagentInfo] {
      Dictionary(uniqueKeysWithValues: metadata.workers.map { worker in
        (
          worker.id,
          ServerSubagentInfo(
            id: worker.id,
            agentType: worker.agentType,
            startedAt: worker.startedAt,
            endedAt: worker.endedAt,
            provider: worker.provider,
            label: worker.title,
            status: worker.status,
            taskSummary: worker.taskSummary,
            resultSummary: worker.resultSummary,
            errorSummary: worker.errorSummary,
            parentSubagentId: worker.parentWorkerID,
            model: worker.model,
            lastActivityAt: worker.lastActivityAt
          )
        )
      })
    }

  }

  private extension Date {
    static let relativeFormatter = RelativeDateTimeFormatter()

    var relativeTimestampLabel: String {
      Date.relativeFormatter.localizedString(for: self, relativeTo: .now)
    }
  }

#endif
