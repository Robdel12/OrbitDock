import SwiftUI

struct SettingsEditorPreferencesSection: View {
  @AppStorage("preferredEditor") private var preferredEditor: String = ""

  private let editors: [(id: String, name: String)] = [
    ("", "System Default (Finder)"),
    ("code", "Visual Studio Code"),
    ("cursor", "Cursor"),
    ("zed", "Zed"),
    ("subl", "Sublime Text"),
    ("emacs", "Emacs"),
    ("vim", "Vim"),
    ("nvim", "Neovim"),
  ]

  var body: some View {
    SettingsSection(title: "EDITOR", icon: "chevron.left.forwardslash.chevron.right") {
      VStack(alignment: .leading, spacing: Spacing.md_) {
        HStack {
          Text("Default Editor")
            .font(.system(size: TypeScale.body))

          Spacer()

          Picker("", selection: $preferredEditor) {
            ForEach(editors, id: \.id) { editor in
              Text(editor.name).tag(editor.id)
            }
          }
          .pickerStyle(.menu)
          .frame(width: 200)
          .tint(Color.accent)
        }

        Text("Used when clicking project paths to open in your editor.")
          .font(.system(size: TypeScale.meta))
          .foregroundStyle(Color.textTertiary)
      }
    }
  }
}
