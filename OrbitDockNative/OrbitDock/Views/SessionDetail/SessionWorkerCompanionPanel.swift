import SwiftUI

struct SessionWorkerCompanionPanel: View {
  let rosterPresentation: SessionWorkerRosterPresentation
  let detailPresentation: SessionWorkerDetailPresentation?
  let selectedWorkerID: String?
  @Binding var messageDraft: String
  let isSendingMessage: Bool
  let sessionId: String
  let endpointId: UUID?
  let clients: ServerClients?
  let onSelectWorker: (String) -> Void
  let onRevealConversationEvent: (String) -> Void
  let onSendMessage: () -> Void

  var body: some View {
    ScrollView(showsIndicators: false) {
      VStack(spacing: 0) {
        SessionWorkerRosterView(
          presentation: rosterPresentation,
          selectedWorkerID: selectedWorkerID,
          onSelectWorker: onSelectWorker
        )

        Divider()
          .foregroundStyle(Color.panelBorder.opacity(0.6))

        VStack(alignment: .leading, spacing: Spacing.md) {
          if let detailPresentation {
            SessionWorkerDetailView(
              presentation: detailPresentation,
              messageDraft: $messageDraft,
              isSendingMessage: isSendingMessage,
              sessionId: sessionId,
              endpointId: endpointId,
              clients: clients,
              onSelectWorker: onSelectWorker,
              onRevealConversationEvent: onRevealConversationEvent,
              onSendMessage: onSendMessage
            )
          } else {
            SessionWorkerEmptyState()
          }
        }
        .padding(.vertical, Spacing.md)
      }
    }
  }
}

struct SessionWorkerDetailView: View {
  let presentation: SessionWorkerDetailPresentation
  @Binding var messageDraft: String
  let isSendingMessage: Bool
  let sessionId: String
  let endpointId: UUID?
  let clients: ServerClients?
  let onSelectWorker: (String) -> Void
  let onRevealConversationEvent: (String) -> Void
  let onSendMessage: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      workerHero

      if presentation.latestConversationEventID != nil || !presentation.relatedWorkers.isEmpty {
        workerActionRail
      }

      if !presentation.detailLines.isEmpty {
        workerFactsGrid
      }

      if !presentation.capabilities.isEmpty {
        capabilityGrid
      }

      if hasAgentThreadEnvelope {
        agentThreadComposer

        agentConversationSection
      }

      missionBriefing

      if !presentation.tools.isEmpty {
        activitySection(
          title: "Tool Feed",
          eyebrow: "Runtime",
          icon: "rectangle.stack.fill",
          accent: Color.accent
        ) {
          VStack(spacing: Spacing.sm) {
            ForEach(presentation.tools) { tool in
              HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: tool.iconName)
                  .font(.system(size: TypeScale.mini, weight: .medium))
                  .foregroundStyle(ToolCardStyle.color(for: tool.toolName))
                  .frame(width: 14, height: 14)
                  .padding(.top, 2)

                VStack(alignment: .leading, spacing: Spacing.xxs) {
                  HStack(spacing: Spacing.xs) {
                    Text(tool.toolName)
                      .font(.system(size: TypeScale.meta, weight: .semibold))
                      .foregroundStyle(Color.textPrimary)

                    Spacer(minLength: 0)

                    compactStatus(label: tool.statusLabel, color: tool.statusColor)
                  }

                  Text(tool.summary)
                    .font(.system(size: TypeScale.meta))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                }
              }
              .padding(.horizontal, Spacing.md)
              .padding(.vertical, Spacing.sm)
              .background(
                Color.backgroundSecondary.opacity(0.72),
                in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
              )
            }
          }
        }
      }

      if !presentation.relatedWorkers.isEmpty {
        activitySection(
          title: "Related Workers",
          eyebrow: "Graph",
          icon: "point.3.connected.trianglepath.dotted",
          accent: Color.accent
        ) {
          VStack(spacing: Spacing.sm) {
            ForEach(presentation.relatedWorkers) { worker in
              Button {
                onSelectWorker(worker.id)
              } label: {
                HStack(spacing: Spacing.sm) {
                  VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(worker.relationshipLabel)
                      .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
                      .foregroundStyle(Color.textQuaternary)

                    Text(worker.title)
                      .font(.system(size: TypeScale.meta, weight: .semibold))
                      .foregroundStyle(Color.textPrimary)
                      .lineLimit(1)
                  }

                  Spacer(minLength: 0)

                  compactStatus(label: worker.statusLabel, color: worker.statusColor)

                  Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Color.accent)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                  Color.backgroundSecondary.opacity(0.62),
                  in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                )
              }
              .buttonStyle(.plain)
            }
          }
        }
      }

      activitySection(
        title: "Conversation Trail",
        eyebrow: "Main thread",
        icon: "point.topleft.down.curvedto.point.bottomright.up.fill",
        accent: Color.statusReply
      ) {
        if presentation.conversationEvents.isEmpty {
          Text(
            presentation.isActive
              ? "Timeline-linked worker activity will appear here as this worker talks back through the main conversation."
              : "No worker-specific conversation events were captured for this run."
          )
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textSecondary)
        } else {
          VStack(spacing: Spacing.sm) {
            ForEach(presentation.conversationEvents) { event in
              Button {
                onRevealConversationEvent(event.id)
              } label: {
                HStack(alignment: .top, spacing: Spacing.sm) {
                  Image(systemName: event.iconName)
                    .font(.system(size: TypeScale.mini, weight: .semibold))
                    .foregroundStyle(event.statusColor)
                    .frame(width: 14, height: 14)
                    .padding(.top, 2)

                  VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.xs) {
                      Text(event.title)
                        .font(.system(size: TypeScale.meta, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)

                      Text(event.statusLabel)
                        .font(.system(size: TypeScale.mini, weight: .medium))
                        .foregroundStyle(event.statusColor)

                      if let timestampLabel = event.timestampLabel {
                        Text(timestampLabel)
                          .font(.system(size: TypeScale.mini))
                          .foregroundStyle(Color.textQuaternary)
                      }
                    }

                    Text(event.summary)
                      .font(.system(size: TypeScale.micro))
                      .foregroundStyle(Color.textSecondary)
                      .fixedSize(horizontal: false, vertical: true)
                      .lineLimit(4)
                  }

                  Spacer(minLength: 0)

                  Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: TypeScale.mini, weight: .semibold))
                    .foregroundStyle(Color.textTertiary)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(
                  Color.backgroundSecondary.opacity(0.62),
                  in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                )
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.top, Spacing.xs)
    .padding(.bottom, Spacing.md)
  }

  private var workerHero: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .fill(Color.backgroundTertiary.opacity(0.95))

          Image(systemName: presentation.iconName)
            .font(.system(size: TypeScale.body, weight: .semibold))
            .foregroundStyle(presentation.statusColor)
        }
        .frame(width: 34, height: 34)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(alignment: .center, spacing: Spacing.xs) {
            Text(presentation.title)
              .font(.system(size: TypeScale.subhead, weight: .semibold))
              .foregroundStyle(Color.textPrimary)

            compactStatus(label: presentation.statusLabel, color: presentation.statusColor)
          }

          if let subtitle = presentation.subtitle {
            Text(subtitle)
              .font(.system(size: TypeScale.body))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }

          Text(presentation.statusNarrative)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textQuaternary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(.horizontal, Spacing.md)
    .padding(.vertical, Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.82))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(Color.panelBorder.opacity(0.42), lineWidth: 1)
        )
    )
  }

  private var workerActionRail: some View {
    HStack(spacing: Spacing.sm) {
      if let latestConversationEventID = presentation.latestConversationEventID {
        Button {
          onRevealConversationEvent(latestConversationEventID)
        } label: {
          Label("Reveal Latest Moment", systemImage: "arrow.up.forward.app")
            .font(.system(size: TypeScale.meta, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .tint(.accent)
      }

      if let activeRelated = presentation.relatedWorkers.first {
        Button {
          onSelectWorker(activeRelated.id)
        } label: {
          Label(activeRelated.title, systemImage: "point.3.connected.trianglepath.dotted")
            .font(.system(size: TypeScale.meta, weight: .semibold))
            .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .tint(activeRelated.statusColor)
      }

      Spacer(minLength: 0)
    }
    .padding(.horizontal, Spacing.xs)
  }

  private var hasAgentThreadEnvelope: Bool {
    !presentation.capabilities.isEmpty
      || !presentation.limitations.isEmpty
      || !presentation.conversationRows.isEmpty
      || presentation.messageModeLabel != nil
  }

  private var capabilityGrid: some View {
    LazyVGrid(
      columns: [
        GridItem(.adaptive(minimum: 128), alignment: .leading),
      ],
      alignment: .leading,
      spacing: Spacing.sm
    ) {
      ForEach(presentation.capabilities) { capability in
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(capability.label.uppercased())
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)

          HStack(spacing: Spacing.xs) {
            Circle()
              .fill(capability.color)
              .frame(width: 6, height: 6)

            Text(capability.value)
              .font(.system(size: TypeScale.meta, weight: .semibold))
              .foregroundStyle(Color.textPrimary)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          Color.backgroundTertiary.opacity(0.62),
          in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
      }
    }
  }

  private var agentThreadComposer: some View {
    activitySection(
      title: "Interject",
      eyebrow: presentation.messageModeLabel ?? "Provider capability",
      icon: "arrow.up.message.fill",
      accent: presentation.canSendMessage ? Color.statusReply : Color.textTertiary
    ) {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        if presentation.canSendMessage {
          TextField("Message this agent", text: $messageDraft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: TypeScale.body))
            .foregroundStyle(Color.textPrimary)
            .lineLimit(2 ... 5)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(
              Color.backgroundSecondary.opacity(0.78),
              in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            )

          HStack(spacing: Spacing.sm) {
            Spacer(minLength: 0)

            Button {
              onSendMessage()
            } label: {
              Label(isSendingMessage ? "Sending" : "Send", systemImage: "arrow.up.circle.fill")
                .font(.system(size: TypeScale.meta, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.statusReply)
            .disabled(isSendingMessage || messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        } else if presentation.limitations.isEmpty {
          Text("This provider exposes this thread as observe-only right now.")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textSecondary)
        } else {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(presentation.limitations, id: \.self) { limitation in
              HStack(alignment: .top, spacing: Spacing.xs) {
                Image(systemName: "info.circle.fill")
                  .font(.system(size: TypeScale.mini, weight: .semibold))
                  .foregroundStyle(Color.textTertiary)
                  .padding(.top, 2)

                Text(limitation)
                  .font(.system(size: TypeScale.meta))
                  .foregroundStyle(Color.textSecondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
      }
    }
  }

  private var agentConversationSection: some View {
    activitySection(
      title: "Conversation",
      eyebrow: presentation.transcriptStatusLabel,
      icon: "text.bubble.fill",
      accent: Color.statusReply
    ) {
      if presentation.conversationRows.isEmpty {
        Text("No transcript rows captured yet.")
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textSecondary)
      } else {
        VStack(spacing: Spacing.sm) {
          ForEach(presentation.conversationRows) { row in
            TimelineRowContent(
              entry: row,
              isExpanded: false,
              sessionId: sessionId,
              endpointId: endpointId,
              clients: clients
            )
            .padding(.vertical, Spacing.xs)
            .background(
              Color.backgroundSecondary.opacity(0.54),
              in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            )
          }
        }
      }
    }
  }

  private var missionBriefing: some View {
    let briefing = missionBriefingMeta

    return activitySection(
      title: briefing.title,
      eyebrow: briefing.eyebrow,
      icon: briefing.icon,
      accent: briefing.accent
    ) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        if let reportPreview = presentation.reportPreview {
          MarkdownContentView(content: reportPreview, style: .standard)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let assignmentPreview = presentation.assignmentPreview {
          Text(assignmentPreview)
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textPrimary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          Text("This worker has been registered, but OrbitDock has not captured a readable brief yet.")
            .font(.system(size: TypeScale.meta))
            .foregroundStyle(Color.textSecondary)
        }

        if presentation.reportPreview != nil, let assignmentPreview = presentation.assignmentPreview {
          VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Original assignment")
              .font(.system(size: TypeScale.mini, weight: .semibold))
              .foregroundStyle(Color.textQuaternary)

            Text(assignmentPreview)
              .font(.system(size: TypeScale.meta))
              .foregroundStyle(Color.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
          }
          .padding(.horizontal, Spacing.md)
          .padding(.vertical, Spacing.sm)
          .background(
            Color.backgroundSecondary.opacity(0.68),
            in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
          )
        }
      }
    }
  }

  private var missionBriefingMeta: (title: String, eyebrow: String, icon: String, accent: Color) {
    if presentation.reportPreview != nil {
      return ("Latest Report", "Returned context", "text.bubble.fill", presentation.statusColor)
    }

    return ("Current Assignment", "Mission brief", "scope", Color.accent)
  }

  private var workerFactsGrid: some View {
    LazyVGrid(
      columns: [
        GridItem(.adaptive(minimum: 128), alignment: .leading),
      ],
      alignment: .leading,
      spacing: Spacing.sm
    ) {
      ForEach(presentation.detailLines) { line in
        VStack(alignment: .leading, spacing: Spacing.xxs) {
          Text(line.label.uppercased())
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)

          Text(line.value)
            .font(.system(size: TypeScale.meta, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
            .textSelection(.enabled)
            .lineLimit(3)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(
          Color.backgroundTertiary.opacity(0.62),
          in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        )
      }
    }
  }

  private func activitySection(
    title: String,
    eyebrow: String,
    icon: String,
    accent: Color,
    @ViewBuilder content: () -> some View
  ) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      HStack(spacing: Spacing.sm) {
        ZStack {
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(accent.opacity(0.14))

          Image(systemName: icon)
            .font(.system(size: TypeScale.micro, weight: .bold))
            .foregroundStyle(accent)
        }
        .frame(width: 20, height: 20)

        VStack(alignment: .leading, spacing: 1) {
          Text(eyebrow.uppercased())
            .font(.system(size: TypeScale.mini, weight: .bold, design: .rounded))
            .foregroundStyle(Color.textQuaternary)

          Text(title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(Color.textPrimary)
        }
      }

      content()
    }
    .padding(.horizontal, Spacing.md_)
    .padding(.vertical, Spacing.md)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundTertiary.opacity(0.58))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(Color.panelBorder.opacity(0.35), lineWidth: 1)
        )
    )
  }

  private func compactStatus(label: String, color: Color) -> some View {
    HStack(spacing: 6) {
      Circle()
        .fill(color)
        .frame(width: 6, height: 6)

      Text(label)
        .font(.system(size: TypeScale.mini, weight: .semibold))
        .foregroundStyle(color)
    }
    .padding(.horizontal, Spacing.xs)
    .padding(.vertical, 5)
    .background(color.opacity(0.12), in: Capsule())
  }
}

private struct SessionWorkerEmptyState: View {
  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Select a worker")
        .font(.system(size: TypeScale.title, weight: .semibold, design: .rounded))
        .foregroundStyle(Color.textPrimary)

      Text(
        "Pick a worker from the deck to inspect its report, status, and recent activity without losing the conversation."
      )
      .font(.system(size: TypeScale.meta))
      .foregroundStyle(Color.textSecondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.xl)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .fill(Color.backgroundSecondary.opacity(0.7))
        .overlay(
          RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
            .stroke(Color.panelBorder.opacity(0.35), lineWidth: 1)
        )
    )
    .padding(.horizontal, Spacing.md)
  }
}

extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
