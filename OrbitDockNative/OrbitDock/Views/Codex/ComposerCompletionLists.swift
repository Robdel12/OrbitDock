//
//  ComposerCompletionLists.swift
//  OrbitDock
//
//  Standalone types used by the composer: completion lists, popovers,
//  command deck items, and draft persistence.
//

import SwiftUI

// MARK: - Skill Completion List

struct SkillCompletionList: View {
  let skills: [ServerSkillMetadata]
  let selectedIndex: Int
  let query: String
  let onSelect: (ServerSkillMetadata) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(skills.prefix(8).enumerated()), id: \.element.id) { index, skill in
            Button { onSelect(skill) } label: {
              HStack(spacing: Spacing.sm) {
                Image(systemName: "bolt.fill")
                  .font(.caption2)
                  .foregroundStyle(Color.accent)
                  .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                  skillNameView(skill.name)
                  if let desc = skill.shortDescription ?? Optional(skill.description), !desc.isEmpty {
                    Text(desc)
                      .font(.caption2)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
                Spacer()
              }
              .padding(.horizontal, Spacing.md_)
              .padding(.vertical, Spacing.sm_)
              .background(index == selectedIndex ? Color.accent.opacity(0.15) : Color.clear)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(index)
          }
        }
      }
      .scrollIndicators(.hidden)
      .onChange(of: selectedIndex) { _, newIndex in
        proxy.scrollTo(newIndex, anchor: .center)
      }
    }
    .frame(maxHeight: 200)
    .background(Color.backgroundPrimary)
    .clipShape(RoundedRectangle(cornerRadius: Radius.ml))
    .themeShadow(Shadow.md)
    .overlay(
      RoundedRectangle(cornerRadius: Radius.ml)
        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
    )
  }

  @ViewBuilder
  private func skillNameView(_ name: String) -> some View {
    if !query.isEmpty, let range = name.range(of: query, options: .caseInsensitive) {
      let before = String(name[name.startIndex ..< range.lowerBound])
      let match = String(name[range])
      let after = String(name[range.upperBound...])
      Text("\(Text(before))\(Text(match).foregroundStyle(Color.accent))\(Text(after))")
        .font(.callout.weight(.medium))
    } else {
      Text(name)
        .font(.callout.weight(.medium))
    }
  }
}

// MARK: - MCP Entry Models

struct ComposerMcpToolEntry: Identifiable {
  let id: String
  let server: String
  let tool: ServerMcpTool
}

struct ComposerMcpResourceEntry: Identifiable {
  let id: String
  let server: String
  let resource: ServerMcpResource
}

// MARK: - Command Deck Item

struct ComposerCommandDeckItem: Identifiable {
  enum Kind {
    case openFilePicker
    case openSkillsPanel
    case toggleShellMode
    case insertText(String)
    case refreshMcp
    case attachFile(ProjectFileIndex.ProjectFile)
    case attachSkill(ServerSkillMetadata)
    case insertMcpTool(server: String, tool: ServerMcpTool)
    case insertMcpResource(server: String, resource: ServerMcpResource)
  }

  let id: String
  let section: String
  let icon: String
  let title: String
  let subtitle: String?
  let tint: Color
  let kind: Kind
}

// MARK: - Command Deck List

struct ComposerCommandDeckList: View {
  let items: [ComposerCommandDeckItem]
  let selectedIndex: Int
  let query: String
  let onSelect: (ComposerCommandDeckItem) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            if index == 0 || items[index - 1].section != item.section {
              HStack(spacing: Spacing.sm_) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                  .fill(item.tint.opacity(OpacityTier.medium))
                  .frame(width: 2, height: 10)

                Text(item.section)
                  .font(.system(size: TypeScale.micro, weight: .bold))
                  .foregroundStyle(Color.textQuaternary)
              }
              .padding(.horizontal, Spacing.md_)
              .padding(.top, index == 0 ? Spacing.sm : Spacing.md_)
              .padding(.bottom, Spacing.xs)
            }

            Button {
              onSelect(item)
            } label: {
              HStack(spacing: Spacing.sm) {
                Image(systemName: item.icon)
                  .font(.system(size: TypeScale.caption, weight: .semibold))
                  .foregroundStyle(item.tint)
                  .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                  highlighted(item.title)
                    .font(.system(size: TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)

                  if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                      .font(.system(size: TypeScale.caption))
                      .foregroundStyle(Color.textTertiary)
                      .lineLimit(1)
                  }
                }

                Spacer()
              }
              .padding(.horizontal, Spacing.md_)
              .padding(.vertical, 7)
              .background(
                index == selectedIndex ? item.tint.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(index)
          }
        }
      }
      .scrollIndicators(.hidden)
      .onChange(of: selectedIndex) { _, newIndex in
        proxy.scrollTo(newIndex, anchor: .center)
      }
    }
    .frame(maxHeight: 290)
    .background(Color.backgroundPrimary)
    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
    .themeShadow(Shadow.md)
    .overlay(
      RoundedRectangle(cornerRadius: Radius.lg)
        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
    )
  }

  private func highlighted(_ text: String) -> Text {
    guard !query.isEmpty, let stringRange = text.range(of: query, options: .caseInsensitive) else {
      return Text(text)
    }
    var attributed = AttributedString(text)
    if let attributedRange = Range(stringRange, in: attributed) {
      attributed[attributedRange].foregroundColor = .accent
    }
    return Text(attributed)
  }
}

// MARK: - File Picker Popover

struct ComposerFilePickerPopover: View {
  @Binding var query: String
  let files: [ProjectFileIndex.ProjectFile]
  let onSelect: (ProjectFileIndex.ProjectFile) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      TextField("Search files…", text: $query)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: TypeScale.subhead))

      if files.isEmpty {
        VStack(spacing: Spacing.sm_) {
          Image(systemName: "doc.text.magnifyingglass")
            .font(.system(size: TypeScale.thinkingHeading1, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
          Text("No files found")
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(files) { file in
              Button {
                onSelect(file)
              } label: {
                HStack(spacing: Spacing.sm) {
                  Image(systemName: fileIcon(for: file.name))
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(Color.composerPrompt)
                    .frame(width: 14)
                  VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(file.name)
                      .font(.system(size: TypeScale.subhead, weight: .semibold))
                      .foregroundStyle(Color.textPrimary)
                    Text(file.relativePath)
                      .font(.system(size: TypeScale.caption, design: .monospaced))
                      .foregroundStyle(Color.textTertiary)
                      .lineLimit(1)
                  }
                  Spacer()
                }
                .padding(.horizontal, Spacing.md_)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(Spacing.md)
    .background(Color.backgroundSecondary)
  }

  private func fileIcon(for name: String) -> String {
    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
    switch ext {
      case "swift": return "swift"
      case "rs": return "gearshape.2"
      case "js", "ts", "jsx", "tsx": return "curlybraces"
      case "py": return "chevron.left.forwardslash.chevron.right"
      case "sh", "bash", "zsh": return "terminal"
      case "json", "yaml", "yml", "toml": return "doc.text"
      case "md", "txt": return "doc.plaintext"
      case "html", "css": return "globe"
      default: return "doc"
    }
  }
}

// MARK: - Claude Model Popover

struct ComposerClaudeModelPopover: View {
  @Binding var selectedModel: String
  let models: [ServerClaudeModelOption]

  @State private var query = ""

  private var filteredModels: [ServerClaudeModelOption] {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return models }
    let lower = trimmed.lowercased()
    return models.filter { option in
      option.displayName.lowercased().contains(lower) ||
        option.value.lowercased().contains(lower) ||
        option.description.lowercased().contains(lower)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.sm) {
      TextField("Search Claude models", text: $query)
        .textFieldStyle(.roundedBorder)
        .font(.system(size: TypeScale.subhead))

      if filteredModels.isEmpty {
        VStack(spacing: Spacing.sm_) {
          Image(systemName: "cpu")
            .font(.system(size: TypeScale.thinkingHeading1, weight: .semibold))
            .foregroundStyle(Color.textQuaternary)
          Text("No Claude models available")
            .font(.system(size: TypeScale.subhead, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(filteredModels) { model in
              let isSelected = model.value == selectedModel
              Button {
                selectedModel = model.value
              } label: {
                HStack(spacing: Spacing.sm) {
                  Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: TypeScale.caption, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.providerClaude : Color.textQuaternary)
                    .frame(width: 14)

                  VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(model.displayName)
                      .font(.system(size: TypeScale.subhead, weight: .semibold))
                      .foregroundStyle(Color.textPrimary)
                    Text(model.value)
                      .font(.system(size: TypeScale.caption, design: .monospaced))
                      .foregroundStyle(Color.textTertiary)
                      .lineLimit(1)
                  }
                  Spacer()
                }
                .padding(.horizontal, Spacing.md_)
                .padding(.vertical, 7)
                .background(
                  isSelected ? Color.providerClaude.opacity(0.14) : Color.clear,
                  in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                )
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
        .scrollIndicators(.hidden)
      }
    }
    .padding(Spacing.md)
    .background(Color.backgroundSecondary)
  }
}

// MARK: - Draft Store

enum ComposerDraftStore {
  private static let keyPrefix = "orbitdock.direct-composer-draft"

  static func load(for key: String, defaults: UserDefaults = .standard) -> String? {
    let value = defaults.string(forKey: storageKey(for: key))
    guard let value, !value.isEmpty else { return nil }
    return value
  }

  static func save(_ value: String, for key: String, defaults: UserDefaults = .standard) {
    let storageKey = storageKey(for: key)
    if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      defaults.removeObject(forKey: storageKey)
      return
    }
    defaults.set(value, forKey: storageKey)
  }

  private static func storageKey(for key: String) -> String {
    "\(keyPrefix).\(key)"
  }
}

// MARK: - Text Editing Helpers

enum ComposerTextEditing {
  static func applySkillCompletion(in message: String, skillName: String) -> String? {
    guard let dollarIdx = message.lastIndex(of: "$") else { return nil }
    let prefix = String(message[..<dollarIdx])
    return prefix + "$" + skillName + " "
  }

  static func applyMentionCompletion(in message: String, fileName: String) -> String? {
    guard let atIdx = message.lastIndex(of: "@") else { return nil }
    let prefix = String(message[..<atIdx])
    return prefix + "@" + fileName + " "
  }

  static func isCommandDeckTokenStart(_ index: String.Index, in text: String) -> Bool {
    if index == text.startIndex {
      return true
    }
    return text[text.index(before: index)].isWhitespace
  }

  static func activateCommandDeckToken(in message: String, prefill: String?) -> String {
    let token = "/" + (prefill ?? "")

    if let slashIdx = message.lastIndex(of: "/") {
      let afterSlash = message[message.index(after: slashIdx)...]
      if isCommandDeckTokenStart(slashIdx, in: message), !afterSlash.contains(where: \.isWhitespace) {
        let prefix = String(message[..<slashIdx])
        return prefix + token
      }
    }

    if message.isEmpty || message.hasSuffix(" ") || message.hasSuffix("\n") {
      return message + token
    }

    return message + " " + token
  }

  static func removingTrailingCommandDeckToken(in message: String) -> String? {
    guard let slashIdx = message.lastIndex(of: "/") else { return nil }
    guard isCommandDeckTokenStart(slashIdx, in: message) else { return nil }
    let afterSlash = message[message.index(after: slashIdx)...]
    guard !afterSlash.contains(where: \.isWhitespace) else { return nil }
    return String(message[..<slashIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func replacingTrailingCommandDeckToken(in message: String, replacement: String, appendSpace: Bool) -> String {
    let suffix = appendSpace ? " " : ""

    guard let slashIdx = message.lastIndex(of: "/"),
          isCommandDeckTokenStart(slashIdx, in: message)
    else {
      let spacer = (message.isEmpty || message.hasSuffix(" ") || message.hasSuffix("\n")) ? "" : " "
      return message + spacer + replacement + suffix
    }

    let afterSlash = message[message.index(after: slashIdx)...]
    guard !afterSlash.contains(where: \.isWhitespace) else {
      let spacer = message.hasSuffix(" ") || message.hasSuffix("\n") ? "" : " "
      return message + spacer + replacement + suffix
    }

    let prefix = String(message[..<slashIdx])
    return prefix + replacement + suffix
  }
}
