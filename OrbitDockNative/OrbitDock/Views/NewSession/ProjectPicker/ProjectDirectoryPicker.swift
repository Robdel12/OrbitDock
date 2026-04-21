import SwiftUI

struct ProjectDirectoryPicker: View {
  enum Style {
    case standalone
    case embedded
  }

  @Binding var selectedPath: String
  @Binding var selectedPathIsGit: Bool
  let endpointId: UUID?
  let style: Style

  init(
    selectedPath: Binding<String>,
    selectedPathIsGit: Binding<Bool> = .constant(true),
    endpointId: UUID? = nil,
    style: Style = .standalone
  ) {
    _selectedPath = selectedPath
    _selectedPathIsGit = selectedPathIsGit
    self.endpointId = endpointId
    self.style = style
  }

  var body: some View {
    #if os(macOS)
      ProjectPicker(
        selectedPath: $selectedPath,
        selectedPathIsGit: $selectedPathIsGit,
        endpointId: endpointId,
        style: style.projectPickerStyle
      )
    #else
      RemoteProjectPicker(
        selectedPath: $selectedPath,
        selectedPathIsGit: $selectedPathIsGit,
        endpointId: endpointId
      )
    #endif
  }
}

#if os(macOS)
  private extension ProjectDirectoryPicker.Style {
    var projectPickerStyle: ProjectPicker.Style {
      switch self {
        case .standalone: .standalone
        case .embedded: .embedded
      }
    }
  }
#endif
