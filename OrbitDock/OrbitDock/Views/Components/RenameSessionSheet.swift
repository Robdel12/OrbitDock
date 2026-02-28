//
//  RenameSessionSheet.swift
//  OrbitDock
//
//  Sheet for renaming a session with custom name override.
//

import SwiftUI

struct RenameSessionSheet: View {
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  #endif

  let session: Session
  let initialText: String
  let onSave: (String) -> Void
  let onCancel: () -> Void

  @State private var text: String = ""
  @FocusState private var isFocused: Bool

  #if os(iOS)
    private var isPhoneCompact: Bool {
      horizontalSizeClass == .compact
    }
  #endif

  var body: some View {
    Group {
      #if os(iOS)
        if isPhoneCompact {
          compactLayout
        } else {
          panelLayout
        }
      #else
        panelLayout
      #endif
    }
    .onAppear {
      text = initialText
      isFocused = true
    }
  }

  private var panelLayout: some View {
    VStack(spacing: 0) {
      // Header
      HStack {
        Text("Rename Session")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
      }
      .padding(.horizontal, 16)
      .padding(.top, 16)
      .padding(.bottom, 12)

      Divider()

      // Content
      formFields
      .padding(16)

      Divider()

      // Actions
      HStack {
        if !initialText.isEmpty {
          Button("Clear Name") {
            onSave("")
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }

        Spacer()

        Button("Cancel") {
          onCancel()
        }
        .keyboardShortcut(.cancelAction)

        Button("Save") {
          onSave(text)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(text == initialText)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .ifMacOS { view in
      view.frame(width: 340)
    }
    .background(Color.panelBackground)
  }

  private var formFields: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Project")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)

        Text(session.projectName ?? session.projectPath.components(separatedBy: "/").last ?? "Unknown")
          .font(.system(size: 13, weight: .medium))
          .foregroundStyle(.primary)
      }

      if let summary = session.summary {
        VStack(alignment: .leading, spacing: 6) {
          Text("\(session.provider.displayName)'s Title")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

          Text(summary.strippingXMLTags())
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
              Color.backgroundTertiary.opacity(0.5),
              in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Custom Name")
          .font(.system(size: 11, weight: .medium))
          .foregroundStyle(.secondary)

        TextField("Override with your own name...", text: $text)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .padding(.horizontal, 10)
          .padding(.vertical, 8)
          .background(Color.backgroundTertiary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .focused($isFocused)
      }

      Text("Leave empty to use the AI-generated title, or set a custom name.")
        .font(.system(size: 11))
        .foregroundStyle(Color.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  #if os(iOS)
    private var compactLayout: some View {
      NavigationStack {
        ScrollView {
          VStack(alignment: .leading, spacing: Spacing.lg) {
            formFields

            if !initialText.isEmpty {
              Button {
                onSave("")
              } label: {
                Label("Use AI Title", systemImage: "sparkles")
                  .font(.system(size: TypeScale.body, weight: .semibold))
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.bordered)
            }
          }
          .padding(.horizontal, Spacing.lg)
          .padding(.top, Spacing.md)
          .padding(.bottom, Spacing.xl)
        }
        .background(Color.backgroundSecondary)
        .navigationTitle("Rename Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
              onCancel()
            }
          }

          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              onSave(text)
            }
            .disabled(text == initialText)
          }
        }
      }
      .presentationDetents([.height(360), .medium])
      .presentationDragIndicator(.visible)
    }
  #endif
}
