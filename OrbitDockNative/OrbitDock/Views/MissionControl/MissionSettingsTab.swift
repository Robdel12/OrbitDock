import SwiftUI

struct MissionSettingsTab: View {
  let settings: MissionSettings?
  let repoRoot: String
  let missionId: String
  let http: ServerHTTPClient?
  let isCompact: Bool
  let onUpdated: () async -> Void

  @State private var isSaving = false
  @State private var saveError: String?
  @State private var showSaveConfirmation = false

  // Trigger
  @State private var triggerKind = "polling"
  @State private var pollInterval: UInt64 = 60
  @State private var editLabels = ""
  @State private var editStates = ""
  @State private var editProject = ""
  @State private var editTeam = ""

  // Provider
  @State private var providerStrategy = "single"
  @State private var primaryProvider = "claude"
  @State private var secondaryProvider = ""
  @State private var maxConcurrent: UInt32 = 3
  @State private var maxConcurrentPrimary: UInt32 = 2

  // Orchestration
  @State private var maxRetries: UInt32 = 3
  @State private var stallTimeout: UInt64 = 600
  @State private var baseBranch = "main"

  /// Prompt (read-only preview)
  @AppStorage("preferredEditor") private var preferredEditor: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.xl) {
      if isCompact {
        // Mobile: everything stacks
        providerSection
        triggerSection
      } else {
        // Desktop: Provider + Trigger side by side
        HStack(alignment: .top, spacing: Spacing.sm) {
          providerSection
          triggerSection
        }
      }

      orchestrationSection

      promptSection

      saveFooter
    }
    .onAppear { populateFromSettings() }
  }

  // MARK: - Provider Section

  private var providerSection: some View {
    instrumentPanel(
      title: "Provider",
      icon: "cpu",
      description: "Which AI agents handle your issues"
    ) {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Strategy
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          sectionLabel("Dispatch Strategy")

          VStack(spacing: Spacing.xs) {
            strategyOption(
              title: "Single",
              description: "One provider handles all issues",
              value: "single"
            )
            strategyOption(
              title: "Priority",
              description: "Primary first, overflow to secondary",
              value: "priority"
            )
            strategyOption(
              title: "Round Robin",
              description: "Alternate between providers",
              value: "round_robin"
            )
          }
        }

        // Provider cards
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          sectionLabel("Primary")

          HStack(spacing: Spacing.sm) {
            providerCard("Claude", value: "claude", icon: "cpu", binding: $primaryProvider)
            providerCard("Codex", value: "codex", icon: "terminal", binding: $primaryProvider)
          }
        }

        if providerStrategy != "single" {
          VStack(alignment: .leading, spacing: Spacing.sm_) {
            sectionLabel("Secondary")

            HStack(spacing: Spacing.sm) {
              providerCard("Claude", value: "claude", icon: "cpu", binding: $secondaryProvider)
              providerCard("Codex", value: "codex", icon: "terminal", binding: $secondaryProvider)
              providerCard("None", value: "", icon: "minus", binding: $secondaryProvider)
            }
          }
        }

        // Concurrency
        concurrencyStepper("Max Concurrent", value: $maxConcurrent, range: 1 ... 20)

        if providerStrategy == "priority" {
          concurrencyStepper("Primary Limit", value: $maxConcurrentPrimary, range: 1 ... 20)
        }
      }
    }
  }

  // MARK: - Trigger Section

  private var triggerSection: some View {
    instrumentPanel(
      title: "Trigger",
      icon: "antenna.radiowaves.left.and.right",
      description: "When and which issues to process"
    ) {
      VStack(alignment: .leading, spacing: Spacing.lg) {
        // Kind
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          sectionLabel("Mode")

          HStack(spacing: Spacing.sm) {
            modeButton("Polling", icon: "arrow.clockwise", value: "polling", selected: triggerKind) {
              triggerKind = "polling"
            }
            modeButton("Manual", icon: "hand.tap", value: "manual_only", selected: triggerKind) {
              triggerKind = "manual_only"
            }
          }
        }

        if triggerKind == "polling" {
          VStack(alignment: .leading, spacing: Spacing.sm_) {
            sectionLabel("Poll Interval")

            WrappingFlowLayout(spacing: Spacing.xs) {
              intervalChip("30s", seconds: 30)
              intervalChip("1m", seconds: 60)
              intervalChip("5m", seconds: 300)
              intervalChip("15m", seconds: 900)
            }
          }
        }

        // Filters
        VStack(alignment: .leading, spacing: Spacing.sm_) {
          sectionLabel("Filters")

          if isCompact {
            compactField("Project", placeholder: "PROJ", text: $editProject)
            compactField("Team", placeholder: "Engineering", text: $editTeam)
          } else {
            HStack(alignment: .top, spacing: Spacing.sm) {
              compactField("Project", placeholder: "PROJ", text: $editProject)
              compactField("Team", placeholder: "Engineering", text: $editTeam)
            }
          }

          compactField("Labels", placeholder: "bug, agent-ready", text: $editLabels)
          compactField("States", placeholder: "Todo, In Progress", text: $editStates)
        }
      }
    }
  }

  // MARK: - Orchestration Section

  private var orchestrationSection: some View {
    instrumentPanel(
      title: "Orchestration",
      icon: "gearshape.2",
      description: "Retry, timeout, and branch settings"
    ) {
      let orchestrationLayout = isCompact
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.lg))
        : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.xl))

      orchestrationLayout {
        // Retries + timeout
        VStack(alignment: .leading, spacing: Spacing.lg) {
          concurrencyStepper("Max Retries", value: $maxRetries, range: 0 ... 10)

          VStack(alignment: .leading, spacing: Spacing.sm_) {
            sectionLabel("Stall Timeout")

            WrappingFlowLayout(spacing: Spacing.xs) {
              intervalChip("5m", seconds: 300, current: stallTimeout) { stallTimeout = 300 }
              intervalChip("10m", seconds: 600, current: stallTimeout) { stallTimeout = 600 }
              intervalChip("30m", seconds: 1_800, current: stallTimeout) { stallTimeout = 1_800 }
              intervalChip("1h", seconds: 3_600, current: stallTimeout) { stallTimeout = 3_600 }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        // Branch + repo
        VStack(alignment: .leading, spacing: Spacing.lg) {
          compactField("Base Branch", placeholder: "main", text: $baseBranch)

          HStack(spacing: Spacing.sm_) {
            Image(systemName: "folder")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(Color.textQuaternary)

            Text(repoRoot)
              .font(.system(size: TypeScale.micro, design: .monospaced))
              .foregroundStyle(Color.textQuaternary)
              .fixedSize(horizontal: false, vertical: true)

            #if os(macOS)
              Spacer()

              Button {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: repoRoot)
              } label: {
                Image(systemName: "arrow.up.right.square")
                  .font(.system(size: 9))
                  .foregroundStyle(Color.textQuaternary)
              }
              .buttonStyle(.plain)
              .help("Reveal in Finder")
            #endif
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  // MARK: - Prompt Template Preview

  private var promptSection: some View {
    let templateText = settings?.promptTemplate ?? ""
    let previewLines = templateText.split(separator: "\n", omittingEmptySubsequences: false).prefix(6)
    let hasContent = !templateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    return instrumentPanel(
      title: "Prompt Template",
      icon: "doc.text",
      description: "Liquid template rendered per issue at dispatch time"
    ) {
      VStack(alignment: .leading, spacing: Spacing.md) {
        if hasContent {
          // Read-only preview of first few lines
          VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
              Text(String(line).isEmpty ? " " : String(line))
                .font(.system(size: TypeScale.micro, design: .monospaced))
                .foregroundStyle(Color.textTertiary)
            }

            if templateText.split(separator: "\n").count > 6 {
              Text("...")
                .font(.system(size: TypeScale.micro, design: .monospaced))
                .foregroundStyle(Color.textQuaternary)
            }
          }
          .padding(Spacing.md)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .fill(Color.backgroundPrimary)
              .overlay(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                  .strokeBorder(Color.surfaceBorder, lineWidth: 1)
              )
          )
        } else {
          HStack(spacing: Spacing.sm) {
            Image(systemName: "doc.text.magnifyingglass")
              .font(.system(size: 12))
              .foregroundStyle(Color.textQuaternary)
            Text("No prompt template configured")
              .font(.system(size: TypeScale.caption))
              .foregroundStyle(Color.textTertiary)
          }
          .padding(Spacing.md)
        }

        // Action row
        HStack(spacing: Spacing.md) {
          #if os(macOS)
            Button {
              openWorkflowInEditor()
            } label: {
              HStack(spacing: Spacing.sm_) {
                Image(systemName: "pencil.and.outline")
                  .font(.system(size: 11, weight: .semibold))
                Text("Edit in \(editorName)")
                  .font(.system(size: TypeScale.caption, weight: .medium))
              }
              .foregroundStyle(Color.accent)
            }
            .buttonStyle(.plain)
          #endif

          Spacer()

          if !isCompact {
            // Variable reference — desktop only, too wide for phone
            HStack(spacing: Spacing.sm) {
              variableTag("issue.identifier")
              variableTag("issue.title")
              variableTag("attempt")
              Text("+3 more")
                .font(.system(size: TypeScale.micro))
                .foregroundStyle(Color.textQuaternary)
            }
          }
        }

        #if os(iOS)
          HStack(spacing: Spacing.sm_) {
            Image(systemName: "doc.text")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
            Text("Edit WORKFLOW.md in your editor of choice — it's a file in your repo's source control.")
              .font(.system(size: TypeScale.micro))
              .foregroundStyle(Color.textTertiary)
              .fixedSize(horizontal: false, vertical: true)
          }
        #else
          Text(
            "The prompt template lives in WORKFLOW.md and supports Liquid syntax. Edit it in your preferred editor for the best experience."
          )
          .font(.system(size: TypeScale.micro))
          .foregroundStyle(Color.textQuaternary)
          .fixedSize(horizontal: false, vertical: true)
        #endif
      }
    }
  }

  private func variableTag(_ name: String) -> some View {
    Text("{{ \(name) }}")
      .font(.system(size: TypeScale.micro, weight: .medium, design: .monospaced))
      .foregroundStyle(Color.accent.opacity(OpacityTier.strong))
      .padding(.horizontal, Spacing.sm_)
      .padding(.vertical, 2)
      .background(
        Color.accent.opacity(OpacityTier.subtle),
        in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
      )
  }

  private var editorName: String {
    switch preferredEditor {
      case "code": "VS Code"
      case "cursor": "Cursor"
      case "zed": "Zed"
      case "subl": "Sublime"
      case "emacs": "Emacs"
      case "vim": "Vim"
      case "nvim": "Neovim"
      default: "Editor"
    }
  }

  private func openWorkflowInEditor() {
    let workflowPath = repoRoot.hasSuffix("/")
      ? repoRoot + "WORKFLOW.md"
      : repoRoot + "/WORKFLOW.md"

    #if os(macOS)
      if !preferredEditor.isEmpty {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [preferredEditor, workflowPath]
        try? process.run()
      } else {
        NSWorkspace.shared.open(URL(fileURLWithPath: workflowPath))
      }
    #else
      // iOS: can't open local files in external editors, but the preview still works
    #endif
  }

  // MARK: - Save Footer

  private var saveFooter: some View {
    VStack(spacing: Spacing.sm) {
      if let saveError {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(Color.feedbackNegative)
          Text(saveError)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.feedbackNegative)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if showSaveConfirmation {
        HStack(spacing: Spacing.sm_) {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(Color.feedbackPositive)
          Text("Saved to WORKFLOW.md")
            .font(.system(size: TypeScale.micro, weight: .medium))
            .foregroundStyle(Color.feedbackPositive)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack(spacing: Spacing.md) {
        // Where it saves indicator
        HStack(spacing: Spacing.xs) {
          Image(systemName: "doc.text")
            .font(.system(size: 9))
            .foregroundStyle(Color.textQuaternary)
          Text("WORKFLOW.md")
            .font(.system(size: TypeScale.micro, design: .monospaced))
            .foregroundStyle(Color.textQuaternary)
        }

        Spacer()

        Button {
          Task { await saveSettings() }
        } label: {
          HStack(spacing: Spacing.sm_) {
            if isSaving {
              ProgressView()
                .controlSize(.mini)
            } else {
              Image(systemName: "arrow.down.doc")
                .font(.system(size: 11, weight: .semibold))
            }
            Text("Save")
              .font(.system(size: TypeScale.body, weight: .semibold))
          }
          .foregroundStyle(.white)
          .padding(.horizontal, isCompact ? Spacing.lg : Spacing.xl)
          .padding(.vertical, Spacing.md_)
          .frame(maxWidth: isCompact ? .infinity : nil)
          .background(Color.accent, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
      }
    }
  }

  // MARK: - Instrument Panel

  private func instrumentPanel<Content: View>(
    title: String,
    icon: String,
    description: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      // Header with accent edge
      HStack(spacing: 0) {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
          .fill(Color.accent)
          .frame(width: EdgeBar.width)
          .padding(.vertical, Spacing.sm)

        VStack(alignment: .leading, spacing: Spacing.xxs) {
          HStack(spacing: Spacing.sm_) {
            Image(systemName: icon)
              .font(.system(size: 11, weight: .bold))
              .foregroundStyle(Color.accent)
            Text(title)
              .font(.system(size: TypeScale.body, weight: .bold))
              .foregroundStyle(Color.textPrimary)
          }

          Text(description)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }
        .padding(.leading, Spacing.md)
      }
      .padding(.horizontal, Spacing.lg)
      .padding(.vertical, Spacing.md)

      Divider()
        .foregroundStyle(Color.surfaceBorder.opacity(OpacityTier.subtle))

      // Content
      content()
        .padding(Spacing.lg)
    }
    .background(
      RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
        .fill(Color.backgroundSecondary)
        .overlay(
          RoundedRectangle(cornerRadius: Radius.ml, style: .continuous)
            .strokeBorder(Color.surfaceBorder.opacity(OpacityTier.subtle), lineWidth: 1)
        )
    )
  }

  // MARK: - Shared Components

  private func sectionLabel(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: TypeScale.micro, weight: .bold))
      .foregroundStyle(Color.textQuaternary)
      .tracking(0.6)
  }

  private func strategyOption(title: String, description: String, value: String) -> some View {
    Button {
      withAnimation(Motion.snappy) { providerStrategy = value }
    } label: {
      HStack(spacing: Spacing.md) {
        // Radio indicator
        ZStack {
          Circle()
            .strokeBorder(providerStrategy == value ? Color.accent : Color.textQuaternary, lineWidth: 1.5)
            .frame(width: 14, height: 14)

          if providerStrategy == value {
            Circle()
              .fill(Color.accent)
              .frame(width: 7, height: 7)
          }
        }

        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(providerStrategy == value ? Color.textPrimary : Color.textSecondary)

          Text(description)
            .font(.system(size: TypeScale.micro))
            .foregroundStyle(Color.textQuaternary)
        }
      }
      .padding(.horizontal, Spacing.md)
      .padding(.vertical, Spacing.sm)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(providerStrategy == value ? Color.accent.opacity(OpacityTier.subtle) : Color.backgroundTertiary
            .opacity(0.5))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .strokeBorder(providerStrategy == value ? Color.accent.opacity(OpacityTier.light) : .clear, lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  private func providerCard(_ label: String, value: String, icon: String, binding: Binding<String>) -> some View {
    let isSelected = binding.wrappedValue == value

    return Button {
      withAnimation(Motion.snappy) { binding.wrappedValue = value }
    } label: {
      VStack(spacing: Spacing.sm_) {
        Image(systemName: icon)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(isSelected ? Color.accent : Color.textTertiary)

        Text(label)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.md)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(isSelected ? Color.accent.opacity(OpacityTier.subtle) : Color.backgroundTertiary.opacity(0.5))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .strokeBorder(
                isSelected ? Color.accent.opacity(OpacityTier.medium) : Color.surfaceBorder.opacity(OpacityTier.subtle),
                lineWidth: 1
              )
          )
      )
    }
    .buttonStyle(.plain)
  }

  private func modeButton(
    _ label: String,
    icon: String,
    value: String,
    selected: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: Spacing.sm_) {
        Image(systemName: icon)
          .font(.system(size: 11, weight: .semibold))
        Text(label)
          .font(.system(size: TypeScale.caption, weight: .medium))
      }
      .foregroundStyle(selected == value ? Color.accent : Color.textSecondary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, Spacing.sm)
      .background(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .fill(selected == value ? Color.accent.opacity(OpacityTier.subtle) : Color.backgroundTertiary.opacity(0.5))
          .overlay(
            RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              .strokeBorder(selected == value ? Color.accent.opacity(OpacityTier.medium) : .clear, lineWidth: 1)
          )
      )
    }
    .buttonStyle(.plain)
  }

  private func compactField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      TextField(placeholder, text: text)
        .textFieldStyle(.plain)
        .font(.system(size: TypeScale.caption, design: .monospaced))
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm_)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(Color.backgroundPrimary)
            .overlay(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(Color.surfaceBorder, lineWidth: 1)
            )
        )
    }
  }

  private func concurrencyStepper(_ label: String, value: Binding<UInt32>, range: ClosedRange<UInt32>) -> some View {
    HStack(spacing: Spacing.md) {
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .medium))
        .foregroundStyle(Color.textTertiary)

      Spacer()

      HStack(spacing: 0) {
        Button {
          if value.wrappedValue > range.lowerBound {
            value.wrappedValue -= 1
          }
        } label: {
          Image(systemName: "minus")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(value.wrappedValue > range.lowerBound ? Color.textSecondary : Color.textQuaternary)
            .frame(width: 28, height: 26)
            .background(Color.backgroundTertiary)
        }
        .buttonStyle(.plain)

        Text("\(value.wrappedValue)")
          .font(.system(size: TypeScale.caption, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.textPrimary)
          .frame(width: 32, height: 26)
          .background(Color.backgroundPrimary)

        Button {
          if value.wrappedValue < range.upperBound {
            value.wrappedValue += 1
          }
        } label: {
          Image(systemName: "plus")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(value.wrappedValue < range.upperBound ? Color.textSecondary : Color.textQuaternary)
            .frame(width: 28, height: 26)
            .background(Color.backgroundTertiary)
        }
        .buttonStyle(.plain)
      }
      .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
          .strokeBorder(Color.surfaceBorder, lineWidth: 1)
      )
    }
  }

  /// Interval chips — for poll interval (uses @State binding)
  private func intervalChip(_ label: String, seconds: UInt64) -> some View {
    Button {
      pollInterval = seconds
    } label: {
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
        .foregroundStyle(pollInterval == seconds ? Color.accent : Color.textTertiary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm_)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(pollInterval == seconds ? Color.accent.opacity(OpacityTier.subtle) : Color.backgroundTertiary
              .opacity(0.5))
            .overlay(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(pollInterval == seconds ? Color.accent.opacity(OpacityTier.medium) : .clear, lineWidth: 1)
            )
        )
    }
    .buttonStyle(.plain)
  }

  /// Interval chips — for arbitrary UInt64 values (stall timeout, etc.)
  private func intervalChip(
    _ label: String,
    seconds: UInt64,
    current: UInt64,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Text(label)
        .font(.system(size: TypeScale.micro, weight: .semibold, design: .monospaced))
        .foregroundStyle(current == seconds ? Color.accent : Color.textTertiary)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm_)
        .background(
          RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
            .fill(current == seconds ? Color.accent.opacity(OpacityTier.subtle) : Color.backgroundTertiary.opacity(0.5))
            .overlay(
              RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                .strokeBorder(current == seconds ? Color.accent.opacity(OpacityTier.medium) : .clear, lineWidth: 1)
            )
        )
    }
    .buttonStyle(.plain)
  }

  // MARK: - Data

  private func populateFromSettings() {
    guard let s = settings else { return }
    triggerKind = s.trigger.kind
    pollInterval = s.trigger.interval
    editLabels = s.trigger.filters.labels.joined(separator: ", ")
    editStates = s.trigger.filters.states.joined(separator: ", ")
    editProject = s.trigger.filters.project ?? ""
    editTeam = s.trigger.filters.team ?? ""
    providerStrategy = s.provider.strategy
    primaryProvider = s.provider.primary
    secondaryProvider = s.provider.secondary ?? ""
    maxConcurrent = s.provider.maxConcurrent
    maxConcurrentPrimary = s.provider.maxConcurrentPrimary ?? 2
    maxRetries = s.orchestration.maxRetries
    stallTimeout = s.orchestration.stallTimeout
    baseBranch = s.orchestration.baseBranch
  }

  private func parseCSV(_ text: String) -> [String] {
    text
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private func saveSettings() async {
    guard let http else { return }

    isSaving = true
    saveError = nil
    showSaveConfirmation = false

    let body = UpdateSettingsBody(
      providerStrategy: providerStrategy,
      primaryProvider: primaryProvider,
      secondaryProvider: secondaryProvider.isEmpty ? .some(nil) : .some(secondaryProvider),
      maxConcurrent: maxConcurrent,
      maxConcurrentPrimary: providerStrategy == "priority" ? .some(maxConcurrentPrimary) : .some(nil),
      triggerKind: triggerKind,
      pollInterval: pollInterval,
      labelFilter: parseCSV(editLabels),
      stateFilter: parseCSV(editStates),
      projectKey: editProject.isEmpty ? .some(nil) : .some(editProject),
      teamKey: editTeam.isEmpty ? .some(nil) : .some(editTeam),
      maxRetries: maxRetries,
      stallTimeout: stallTimeout,
      baseBranch: baseBranch,
      promptTemplate: nil
    )

    do {
      let _: SettingsUpdateResponse = try await http.request(
        path: "/api/missions/\(missionId)/settings",
        method: "PUT",
        body: body
      )
      showSaveConfirmation = true
      await onUpdated()
    } catch {
      saveError = "Save failed: \(error.localizedDescription)"
    }

    isSaving = false
  }
}

// MARK: - Network Types

private struct UpdateSettingsBody: Encodable {
  let providerStrategy: String?
  let primaryProvider: String?
  let secondaryProvider: OptionalString?
  let maxConcurrent: UInt32?
  let maxConcurrentPrimary: OptionalUInt32?
  let triggerKind: String?
  let pollInterval: UInt64?
  let labelFilter: [String]?
  let stateFilter: [String]?
  let projectKey: OptionalString?
  let teamKey: OptionalString?
  let maxRetries: UInt32?
  let stallTimeout: UInt64?
  let baseBranch: String?
  let promptTemplate: String?

  enum CodingKeys: String, CodingKey {
    case providerStrategy = "provider_strategy"
    case primaryProvider = "primary_provider"
    case secondaryProvider = "secondary_provider"
    case maxConcurrent = "max_concurrent"
    case maxConcurrentPrimary = "max_concurrent_primary"
    case triggerKind = "trigger_kind"
    case pollInterval = "poll_interval"
    case labelFilter = "label_filter"
    case stateFilter = "state_filter"
    case projectKey = "project_key"
    case teamKey = "team_key"
    case maxRetries = "max_retries"
    case stallTimeout = "stall_timeout"
    case baseBranch = "base_branch"
    case promptTemplate = "prompt_template"
  }
}

private enum OptionalString: Encodable {
  case some(String)
  case none

  static func some(_ value: String?) -> OptionalString {
    if let value { .some(value) } else { .none }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
      case let .some(value): try container.encode(value)
      case .none: try container.encodeNil()
    }
  }
}

private enum OptionalUInt32: Encodable {
  case some(UInt32)
  case none

  static func some(_ value: UInt32?) -> OptionalUInt32 {
    if let value { .some(value) } else { .none }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
      case let .some(value): try container.encode(value)
      case .none: try container.encodeNil()
    }
  }
}

private struct SettingsUpdateResponse: Decodable {
  let summary: MissionSummary
}
