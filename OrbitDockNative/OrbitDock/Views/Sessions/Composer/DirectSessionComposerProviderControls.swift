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
    .platformPopover(isPresented: $composerState.showModelEffortPopover) {
      #if os(iOS)
        NavigationStack {
          ModelEffortPopover(
            selectedModel: $composerState.selectedModel,
            selectedEffort: $composerState.selectedEffort,
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
          selectedModel: $composerState.selectedModel,
          selectedEffort: $composerState.selectedEffort,
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
    .platformPopover(isPresented: $composerState.showClaudeModelPopover) {
      #if os(iOS)
        NavigationStack {
          ComposerClaudeModelPopover(
            selectedModel: $composerState.selectedClaudeModel,
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
          selectedModel: $composerState.selectedClaudeModel,
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
