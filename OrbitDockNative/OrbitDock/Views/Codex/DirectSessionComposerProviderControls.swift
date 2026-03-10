import SwiftUI

extension DirectSessionComposer {
  var modelEffortControlButton: some View {
    Button {
      showModelEffortPopover.toggle()
      Platform.services.playHaptic(.selection)
    } label: {
      ghostActionLabel(icon: "slider.horizontal.3", isActive: hasOverrides)
    }
    .buttonStyle(.plain)
    .help("Model and reasoning effort")
    .platformPopover(isPresented: $showModelEffortPopover) {
      #if os(iOS)
        NavigationStack {
          ModelEffortPopover(
            selectedModel: $selectedModel,
            selectedEffort: $selectedEffort,
            models: codexModelOptions
          )
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showModelEffortPopover = false }
            }
          }
        }
      #else
        ModelEffortPopover(
          selectedModel: $selectedModel,
          selectedEffort: $selectedEffort,
          models: codexModelOptions
        )
      #endif
    }
  }

  var claudeModelControlButton: some View {
    Button {
      showClaudeModelPopover.toggle()
      Platform.services.playHaptic(.selection)
    } label: {
      ghostActionLabel(icon: "slider.horizontal.3", isActive: hasOverrides, tint: .providerClaude)
    }
    .buttonStyle(.plain)
    .help("Claude model override")
    .platformPopover(isPresented: $showClaudeModelPopover) {
      #if os(iOS)
        NavigationStack {
          ComposerClaudeModelPopover(
            selectedModel: $selectedClaudeModel,
            models: claudeModelOptions
          )
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { showClaudeModelPopover = false }
            }
          }
        }
      #else
        ComposerClaudeModelPopover(
          selectedModel: $selectedClaudeModel,
          models: claudeModelOptions
        )
      #endif
    }
  }

  @ViewBuilder
  var providerModelControlButton: some View {
    if obs.isDirectCodex {
      modelEffortControlButton
    } else if obs.isDirectClaude {
      claudeModelControlButton
    }
  }
}
