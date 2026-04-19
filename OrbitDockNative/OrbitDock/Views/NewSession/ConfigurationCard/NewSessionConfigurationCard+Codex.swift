import SwiftUI

extension NewSessionConfigurationCard {
  @ViewBuilder
  var codexModelPicker: some View {
    if codexConfigMode == .inherit {
      Text("From Codex config")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
    } else if codexConfigMode == .profile {
      Text(selectedProfileSummary?.model ?? "From selected profile")
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
    } else {
      VStack(alignment: .trailing, spacing: Spacing.xs) {
        TextField("qwen/qwen3-coder-next", text: $codexModel)
          .textFieldStyle(.roundedBorder)
          .font(.system(size: TypeScale.body, design: .monospaced))
          .frame(maxWidth: 240)

        if !codexModels.isEmpty {
          Picker("Suggested model", selection: $codexModel) {
            Text("Suggested models").tag("")
            ForEach(codexModels.filter { !$0.model.isEmpty }, id: \.id) { model in
              Text(model.displayName).tag(model.model)
            }
          }
          .pickerStyle(.menu)
          .labelsHidden()
          .fixedSize()
        }
      }
    }
  }

  var codexConfigurationModeRow: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      codexModeSelector

      if codexConfigMode == .profile {
        HStack(spacing: Spacing.sm) {
          Picker("Profile", selection: $codexConfigProfile) {
            Text(profileOptions.isEmpty ? "No profiles found" : "Select a profile").tag("")
            ForEach(profileOptions) { profile in
              Text(profile.name).tag(profile.name)
            }
          }
          .pickerStyle(.menu)
          .disabled(profileOptions.isEmpty)

          Spacer()
        }
      }

      if provider == .codex, !hasSelectedPath, codexConfigMode == .inherit {
        codexLaunchHintCard(
          title: "Choose a workspace first",
          detail: "OrbitDock needs a folder to resolve Codex defaults for that project.",
          tint: .statusQuestion,
          icon: "folder.badge.questionmark"
        )
      }

      if let codexCatalogError, !codexCatalogError.isEmpty {
        Text(codexCatalogError)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.feedbackNegative)
          .fixedSize(horizontal: false, vertical: true)
      } else if codexCatalogLoading {
        HStack(spacing: Spacing.sm) {
          ProgressView()
            .controlSize(.small)
          Text("Loading profiles…")
            .font(.system(size: TypeScale.caption))
            .foregroundStyle(Color.textTertiary)
        }
      }

      codexActionLinks
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
    .onChange(of: codexConfigMode) { _, newValue in
      switch newValue {
        case .inherit:
          codexModel = ""
          codexConfigProfile = ""
          codexModelProvider = ""
        case .profile:
          codexModel = ""
          codexModelProvider = ""
          if codexConfigProfile.isEmpty {
            codexConfigProfile = profileOptions.first?.name ?? ""
          }
        case .custom:
          codexConfigProfile = ""
          if codexModel.isEmpty {
            codexModel = currentCodexModelOption?.model
              ?? codexModels.first(where: \.isDefault)?.model
              ?? codexModels.first(where: { !$0.model.isEmpty })?.model
              ?? ""
          }
          if codexModelProvider.isEmpty {
            codexModelProvider = providerOptions.first?.id ?? ""
          }
      }
    }
  }

  var codexActionLinks: some View {
    HStack(spacing: Spacing.lg) {
      if let onManageCodexConfig {
        Button {
          onManageCodexConfig()
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "folder.badge.gearshape")
              .font(.system(size: 10, weight: .medium))
            Text("Manage")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(Color.textTertiary)
        }
        .buttonStyle(.plain)
        .platformCursorOnHover()
      }

      if let onInspectCodexConfig {
        Button {
          onInspectCodexConfig()
        } label: {
          HStack(spacing: Spacing.xs) {
            Image(systemName: "doc.text.magnifyingglass")
              .font(.system(size: 10, weight: .medium))
            Text("Inspect")
              .font(.system(size: TypeScale.caption, weight: .medium))
          }
          .foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
        .platformCursorOnHover()
      }

      Spacer()
    }
  }

  var codexModeSelector: some View {
    HStack(spacing: Spacing.xs) {
      codexModeButton(title: "Folder", mode: .inherit)
      codexModeButton(title: "Profile", mode: .profile)
      codexModeButton(title: "Custom", mode: .custom)
    }
    .padding(Spacing.xxs)
    .background(Color.backgroundSecondary, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  func codexModeButton(title: String, mode: ServerCodexConfigMode) -> some View {
    let isSelected = codexConfigMode == mode
    return Button {
      codexConfigMode = mode
    } label: {
      Text(title)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(isSelected ? Color.backgroundPrimary : Color.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.sm)
        .background(
          RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(isSelected ? Color.providerCodex : Color.clear)
        )
    }
    .buttonStyle(.plain)
  }

  func codexLaunchHintCard(title: String, detail: String, tint: Color, icon: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      Image(systemName: icon)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 18, height: 18)

      VStack(alignment: .leading, spacing: Spacing.xxs) {
        Text(title)
          .font(.system(size: TypeScale.caption, weight: .semibold))
          .foregroundStyle(Color.textPrimary)
        Text(detail)
          .font(.system(size: TypeScale.caption))
          .foregroundStyle(Color.textTertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Spacing.md)
    .background(tint.opacity(OpacityTier.tint), in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(tint.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  var codexResolvedValuesSection: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: Spacing.sm) {
        codexResolvedValueCard(title: "Source", value: codexResolvedProfileLabel, tint: Color.providerCodex)
        codexResolvedValueCard(title: "Provider", value: codexResolvedProviderLabel, tint: Color.textSecondary)
        codexResolvedValueCard(title: "Model", value: codexResolvedModelLabel, tint: Color.accent)
      }

      VStack(alignment: .leading, spacing: Spacing.sm) {
        codexResolvedValueCard(title: "Source", value: codexResolvedProfileLabel, tint: Color.providerCodex)
        codexResolvedValueCard(title: "Provider", value: codexResolvedProviderLabel, tint: Color.textSecondary)
        codexResolvedValueCard(title: "Model", value: codexResolvedModelLabel, tint: Color.accent)
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.md)
  }

  func codexResolvedValueCard(title: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: Spacing.xs) {
      Text(title)
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      Text(value)
        .font(.system(size: TypeScale.caption, weight: .semibold))
        .foregroundStyle(tint)
        .lineLimit(2)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  var codexCustomIdentitySection: some View {
    HStack(alignment: .top, spacing: Spacing.md) {
      codexProviderCluster
      codexModelCluster
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  var codexProviderCluster: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("PROVIDER")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      Picker("Provider", selection: $codexModelProvider) {
        Text(providerOptions.isEmpty ? "None found" : "Select").tag("")
        ForEach(providerOptions) { provider in
          Text(provider.displayName ?? provider.id).tag(provider.id)
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  var codexModelCluster: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      Text("MODEL")
        .font(.system(size: TypeScale.micro, weight: .semibold))
        .foregroundStyle(Color.textTertiary)
        .textCase(.uppercase)
        .tracking(0.5)

      TextField("model-id", text: $codexModel)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: TypeScale.caption, design: .monospaced))

      if !codexModels.isEmpty {
        Picker("Suggested", selection: $codexModel) {
          Text("Suggested").tag("")
          ForEach(codexModels.filter { !$0.model.isEmpty }, id: \.id) { model in
            Text(model.displayName).tag(model.model)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      if let codexScopedModelNotice {
        codexScopedModelNoticeView(codexScopedModelNotice)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(Spacing.md)
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
  }

  func codexScopedModelNoticeView(_ message: String) -> some View {
    HStack(alignment: .top, spacing: Spacing.sm) {
      if codexScopedModelsLoading {
        ProgressView()
          .controlSize(.small)
      } else {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: TypeScale.micro, weight: .semibold))
          .foregroundStyle(Color.feedbackCaution)
      }

      Text(message)
        .font(.system(size: TypeScale.micro))
        .foregroundStyle(Color.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  var codexBehaviorCluster: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: Spacing.sm) {
        HStack {
          HStack(spacing: Spacing.sm) {
            Image(systemName: selectedAutonomy.icon)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(selectedAutonomy.color)
            Text("Autonomy")
              .font(.system(size: TypeScale.body, weight: .medium))
              .foregroundStyle(Color.textSecondary)
          }

          Spacer()

          CompactAutonomySelector(selection: $selectedAutonomy)
        }

        HStack(spacing: Spacing.sm) {
          Capsule()
            .fill(selectedAutonomy.color)
            .frame(width: EdgeBar.width, height: 14)

          Text(selectedAutonomy.displayName)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(selectedAutonomy.color)

          HStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.xxs) {
              Image(
                systemName: selectedAutonomy.approvalBehavior
                  .contains("Never") ? "hand.raised.slash" : "hand.raised.fill"
              )
              .font(.system(size: 8))
              Text(selectedAutonomy.approvalBehavior)
                .font(.system(size: TypeScale.micro, weight: .medium))
            }

            Text("·")
              .foregroundStyle(Color.textQuaternary)

            HStack(spacing: Spacing.xxs) {
              Image(systemName: selectedAutonomy.isSandboxed ? "shield.fill" : "shield.slash")
                .font(.system(size: 8))
              Text(selectedAutonomy.isSandboxed ? "Sandboxed" : "No sandbox")
                .font(.system(size: TypeScale.micro, weight: .medium))
            }
            .foregroundStyle(
              selectedAutonomy.isSandboxed ? Color.textQuaternary : Color.autonomyOpen.opacity(0.7)
            )
          }
          .foregroundStyle(Color.textQuaternary)
        }
        .animation(Motion.bouncy, value: selectedAutonomy)
      }
      .padding(Spacing.md)

      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.light))
        .frame(height: 1)
        .padding(.horizontal, Spacing.sm)

      HStack {
        HStack(spacing: Spacing.sm) {
          Image(systemName: codexCollaborationMode.icon)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(codexCollaborationMode.color)
          Text("Collaboration")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          Capsule()
            .fill(codexCollaborationMode.color)
            .frame(width: EdgeBar.width, height: 14)

          Text(codexCollaborationMode.displayName)
            .font(.system(size: TypeScale.caption, weight: .semibold))
            .foregroundStyle(codexCollaborationMode.color)
        }
        .animation(Motion.bouncy, value: codexCollaborationMode)

        Spacer()

        Picker("Collaboration", selection: $codexCollaborationMode) {
          ForEach(availableCodexCollaborationModes) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
      }
      .padding(Spacing.md)

      Rectangle()
        .fill(Color.surfaceBorder.opacity(OpacityTier.light))
        .frame(height: 1)
        .padding(.horizontal, Spacing.sm)

      HStack(alignment: .center, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
          Image(systemName: codexMultiAgentEnabled ? "person.3.fill" : "person.3")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(codexMultiAgentEnabled ? Color.providerCodex : Color.textTertiary)
          Text("Workers")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          if codexMultiAgentIsExperimental {
            Text("BETA")
              .font(.system(size: 7, weight: .bold, design: .rounded))
              .foregroundStyle(Color.feedbackCaution)
              .padding(.horizontal, 5)
              .padding(.vertical, 1.5)
              .background(Color.feedbackCaution.opacity(OpacityTier.light), in: Capsule())
          }

          Text(codexMultiAgentEnabled ? "Enabled" : "Off")
            .font(.system(size: TypeScale.caption, weight: .medium))
            .foregroundStyle(codexMultiAgentEnabled ? Color.providerCodex : Color.textQuaternary)
        }

        Spacer()

        Toggle("", isOn: $codexMultiAgentEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .disabled(!codexSupportsMultiAgent)
      }
      .padding(Spacing.md)
    }
    .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
    )
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  var codexAdvancedSettingsSection: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Button {
        withAnimation(Motion.standard) {
          showCodexAdvancedSettings.toggle()
        }
      } label: {
        HStack(spacing: Spacing.sm) {
          Image(systemName: "slider.horizontal.below.rectangle")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.providerCodex)

          Text("Advanced")
            .font(.system(size: TypeScale.body, weight: .medium))
            .foregroundStyle(Color.textSecondary)

          if !showCodexAdvancedSettings, !codexAdvancedSummary.isEmpty {
            Text(codexAdvancedSummary)
              .font(.system(size: TypeScale.caption, weight: .medium))
              .foregroundStyle(Color.textQuaternary)
              .lineLimit(1)
          }

          Spacer()

          Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
            .rotationEffect(.degrees(showCodexAdvancedSettings ? 90 : 0))
            .animation(Motion.snappy, value: showCodexAdvancedSettings)
        }
      }
      .buttonStyle(.plain)
      .platformCursorOnHover()

      if showCodexAdvancedSettings {
        VStack(alignment: .leading, spacing: Spacing.md) {
          HStack(alignment: .top, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
              Text("PERSONALITY")
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)

              if codexSupportsPersonality {
                Picker("Personality", selection: $codexPersonality) {
                  ForEach(CodexPersonalityPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                  }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
              } else {
                Text("Unavailable")
                  .font(.system(size: TypeScale.caption, weight: .medium))
                  .foregroundStyle(Color.textQuaternary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: Spacing.sm) {
              Text("SERVICE TIER")
                .font(.system(size: TypeScale.micro, weight: .semibold))
                .foregroundStyle(Color.textTertiary)
                .textCase(.uppercase)
                .tracking(0.5)

              Picker("Service Tier", selection: $codexServiceTier) {
                ForEach(availableCodexServiceTiers) { preset in
                  Text(preset.displayName).tag(preset)
                }
              }
              .pickerStyle(.menu)
              .labelsHidden()
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.md)
            .background(Color.backgroundCode, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
            )
          }

          VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("INSTRUCTIONS")
              .font(.system(size: TypeScale.micro, weight: .semibold))
              .foregroundStyle(Color.textTertiary)
              .textCase(.uppercase)
              .tracking(0.5)

            if codexSupportsDeveloperInstructions {
              ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                  .fill(Color.backgroundCode)
                  .overlay(
                    RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                      .stroke(Color.surfaceBorder.opacity(OpacityTier.light), lineWidth: 1)
                  )

                if codexInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                  Text("House rules, code style, team tone…")
                    .font(.system(size: TypeScale.caption))
                    .foregroundStyle(Color.textQuaternary)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                }

                TextEditor(text: $codexInstructions)
                  .font(.system(size: TypeScale.body))
                  .foregroundStyle(Color.textPrimary)
                  .scrollContentBackground(.hidden)
                  .frame(minHeight: 72, maxHeight: 100)
                  .padding(.horizontal, Spacing.sm)
                  .padding(.vertical, Spacing.xs)
              }
            } else {
              Text("Not available for this model.")
                .font(.system(size: TypeScale.caption))
                .foregroundStyle(Color.textQuaternary)
            }
          }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
      }
    }
    .padding(.horizontal, Spacing.lg)
    .padding(.vertical, Spacing.sm)
  }

  var codexAdvancedSummary: String {
    var summary: [String] = []

    if codexPersonality != .automatic {
      summary.append(codexPersonality.displayName)
    }
    if codexServiceTier != .automatic {
      summary.append(codexServiceTier.displayName)
    }
    if !codexInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      summary.append("Instructions set")
    }

    return summary.joined(separator: " · ")
  }
}
