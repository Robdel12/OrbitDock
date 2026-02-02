//
//  Theme.swift
//  OrbitDock
//
//  Design system for OrbitDock - "Cosmic Harbor" theme
//  A space mission control center for AI agent sessions
//
//  Cyan orbit ring as hero accent on deep space backgrounds
//  with subtle nebula undertones
//

import SwiftUI

// MARK: - Design System

extension Color {

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Brand - The Orbit

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Primary brand color - Cyan orbit ring from icon (the hero color)
  static let accent = Color(red: 0.25, green: 0.85, blue: 0.95)

  /// Slightly brighter for glow effects
  static let accentGlow = Color(red: 0.35, green: 0.9, blue: 1.0)

  /// Muted accent for subtle highlights
  static let accentMuted = Color(red: 0.2, green: 0.5, blue: 0.6)

  /// Alias for backwards compatibility
  static let accentPrimary = accent

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Backgrounds - Deep Space with Nebula Undertones

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Main content area - void black with deep blue-violet undertone
  static let backgroundPrimary = Color(red: 0.035, green: 0.04, blue: 0.065)

  /// Elevated surfaces (sidebars, headers) - nebula purple atmosphere
  static let backgroundSecondary = Color(red: 0.055, green: 0.058, blue: 0.095)

  /// Cards, code blocks - cosmic dust with purple tint
  static let backgroundTertiary = Color(red: 0.075, green: 0.078, blue: 0.12)

  /// Slide-in panels - deep space with blue cast
  static let panelBackground = Color(red: 0.045, green: 0.05, blue: 0.085)

  /// Panel borders - subtle cyan tint
  static let panelBorder = accent.opacity(0.1)

  /// Code blocks - darker void
  static let backgroundCode = Color(red: 0.03, green: 0.035, blue: 0.055)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Surfaces - Interaction States (Cyan-tinted)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let surfaceHover = accent.opacity(0.08)
  static let surfaceSelected = accent.opacity(0.15)
  static let surfaceBorder = accent.opacity(0.12)
  static let surfaceActive = accent.opacity(0.22)

  /// Row highlight with subtle nebula tint
  static let rowHighlight = Color(red: 0.15, green: 0.2, blue: 0.35).opacity(0.4)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Text Hierarchy

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let textPrimary = Color.white.opacity(0.92)
  static let textSecondary = Color.white.opacity(0.55)
  static let textTertiary = Color.white.opacity(0.35)
  static let textQuaternary = Color.white.opacity(0.20)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Provider Colors - Multi-Provider Support

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Claude accent - uses brand cyan
  static let providerClaude = accent

  /// Codex/OpenAI accent - green (#4AC78F)
  static let providerCodex = Color(red: 0.29, green: 0.78, blue: 0.56)

  /// Gemini accent - purple/blue
  static let providerGemini = Color(red: 0.4, green: 0.5, blue: 0.9)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Status - Mission Control Indicators

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  //
  // Status color hierarchy (from most to least urgent):
  // 1. Attention (amber) - Needs YOUR action: permission, question
  // 2. Working (cyan)    - Claude actively processing
  // 3. Ready (green)     - Claude done, ball in your court (low urgency)
  // 4. Ended (gray)      - Session finished
  //

  /// Active/Working - Cyan orbit (session in flight)
  static let statusWorking = accent

  /// Needs attention - Amber beacon (permission OR question - you need to act)
  static let statusAttention = Color(red: 1.0, green: 0.7, blue: 0.25)

  /// Waiting for input - Amber beacon (legacy alias)
  static let statusWaiting = statusAttention

  /// Permission required - Same as attention (consolidated)
  static let statusPermission = statusAttention

  /// Error - Red warning
  static let statusError = Color(red: 0.95, green: 0.4, blue: 0.45)

  /// Ready/Complete - Soft green (Claude finished, low urgency)
  static let statusReady = Color(red: 0.35, green: 0.85, blue: 0.55)

  /// Success - Alias for ready
  static let statusSuccess = statusReady

  /// Ended/Idle - Muted purple-gray (inactive but not invisible)
  static let statusEnded = Color(red: 0.45, green: 0.42, blue: 0.55)

  /// Idle - Alias for ended
  static let statusIdle = statusEnded

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Model Colors - Crew Ranks

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let modelOpus = Color(red: 0.7, green: 0.45, blue: 0.95) // Cosmic purple
  static let modelSonnet = Color(red: 0.4, green: 0.65, blue: 1.0) // Nebula blue
  static let modelHaiku = Color(red: 0.3, green: 0.85, blue: 0.8) // Aqua teal

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Tool Colors - Operations Palette

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let toolRead = Color(red: 0.45, green: 0.7, blue: 1.0) // Scanner blue
  static let toolWrite = Color(red: 1.0, green: 0.6, blue: 0.3) // Thruster orange
  static let toolBash = Color(red: 0.35, green: 0.85, blue: 0.55) // Terminal green
  static let toolSearch = Color(red: 0.65, green: 0.5, blue: 0.95) // Radar purple
  static let toolTask = Color(red: 0.5, green: 0.55, blue: 1.0) // Subspace indigo
  static let toolWeb = accent // Uses brand cyan
  static let toolQuestion = Color(red: 1.0, green: 0.7, blue: 0.3) // Beacon amber
  static let toolMcp = Color(red: 0.55, green: 0.7, blue: 0.85) // Dock gray-blue
  static let toolSkill = Color(red: 0.85, green: 0.55, blue: 0.9) // Warp pink
  static let toolPlan = Color(red: 0.4, green: 0.75, blue: 0.55) // Navigate green
  static let toolTodo = Color(red: 0.7, green: 0.8, blue: 0.45) // Manifest lime

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: MCP Server Colors - Docked Services

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let serverGitHub = Color(red: 0.6, green: 0.5, blue: 1.0) // Nebula purple
  static let serverLinear = Color(red: 0.4, green: 0.55, blue: 1.0) // Deep blue
  static let serverChrome = Color(red: 1.0, green: 0.65, blue: 0.25) // Solar orange
  static let serverSlack = Color(red: 0.95, green: 0.4, blue: 0.6) // Nova pink
  static let serverApple = Color(red: 0.45, green: 0.75, blue: 1.0) // Sky blue
  static let serverDefault = accentMuted // Uses muted accent

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Syntax Highlighting - Code Telescope

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let syntaxKeyword = Color(red: 0.75, green: 0.5, blue: 0.95) // Nebula purple
  static let syntaxString = Color(red: 0.95, green: 0.65, blue: 0.4) // Solar orange
  static let syntaxNumber = Color(red: 0.7, green: 0.85, blue: 0.5) // Starchart lime
  static let syntaxComment = Color(red: 0.4, green: 0.45, blue: 0.5) // Distant star gray
  static let syntaxType = accent // Orbit cyan
  static let syntaxFunction = Color(red: 0.9, green: 0.85, blue: 0.55) // Signal yellow
  static let syntaxProperty = Color(red: 0.55, green: 0.75, blue: 0.95) // Atmosphere blue
  static let syntaxText = Color(red: 0.85, green: 0.87, blue: 0.9) // Starlight

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Language Badge Colors

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let langSwift = Color(red: 1.0, green: 0.55, blue: 0.3) // Orange
  static let langJavaScript = Color(red: 0.95, green: 0.85, blue: 0.4) // Yellow
  static let langPython = Color(red: 0.4, green: 0.65, blue: 1.0) // Blue
  static let langRuby = Color(red: 0.95, green: 0.4, blue: 0.4) // Red
  static let langGo = accent // Cyan (brand!)
  static let langRust = Color(red: 0.95, green: 0.55, blue: 0.3) // Orange
  static let langBash = Color(red: 0.35, green: 0.85, blue: 0.55) // Green
  static let langJSON = Color(red: 0.7, green: 0.5, blue: 0.95) // Purple
  static let langHTML = Color(red: 0.95, green: 0.45, blue: 0.4) // Red
  static let langCSS = Color(red: 0.4, green: 0.55, blue: 1.0) // Blue
  static let langSQL = accent // Cyan (brand!)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Markdown Theme

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let markdownInlineCode = Color(red: 0.95, green: 0.7, blue: 0.45) // Warm signal
  static let markdownLink = accent // Orbit cyan links!
  static let markdownBlockquote = Color(red: 0.6, green: 0.5, blue: 0.9) // Nebula purple

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Git / Branch - Navigation

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let gitBranch = Color(red: 0.95, green: 0.65, blue: 0.3) // Flight path orange

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Terminal - Uplink

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let terminal = Color(red: 0.35, green: 0.85, blue: 0.55) // Uplink green

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Special Effects - Cosmic Atmosphere

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// For active session "in orbit" glow rings
  static let orbitGlow = accent.opacity(0.4)

  /// For attention-needed pulsing
  static let beaconPulse = statusWaiting

  /// Nebula gradient start (purple)
  static let nebulaStart = Color(red: 0.25, green: 0.15, blue: 0.4)

  /// Nebula gradient end (blue)
  static let nebulaEnd = Color(red: 0.1, green: 0.15, blue: 0.35)

  /// Starfield highlight
  static let starlight = Color.white.opacity(0.85)

  /// Void shadow
  static let voidBlack = Color(red: 0.02, green: 0.02, blue: 0.04)

  /// Docked/Ready state - use accent for brand cohesion
  static let statusDocked = accent
}

// MARK: - Theme View Modifier

struct DarkTheme: ViewModifier {
  func body(content: Content) -> some View {
    content
      .preferredColorScheme(.dark)
  }
}

extension View {
  func darkTheme() -> some View {
    modifier(DarkTheme())
  }
}

// MARK: - Unified Session Status

/// Unified session status for consistent badge display across the app
enum SessionDisplayStatus {
  case working // Claude actively processing (cyan)
  case attention // Needs your action: permission or question (amber)
  case ready // Claude done, waiting for your next prompt (green)
  case ended // Session finished (muted purple-gray)

  var color: Color {
    switch self {
      case .working: .statusWorking
      case .attention: .statusAttention
      case .ready: .statusReady
      case .ended: .statusEnded
    }
  }

  var label: String {
    switch self {
      case .working: "Working"
      case .attention: "Attention"
      case .ready: "Ready"
      case .ended: "Ended"
    }
  }

  var icon: String {
    switch self {
      case .working: "bolt.fill"
      case .attention: "exclamationmark.circle.fill"
      case .ready: "checkmark.circle"
      case .ended: "moon.fill"
    }
  }

  /// Create from Session model
  static func from(_ session: Session) -> SessionDisplayStatus {
    guard session.isActive else { return .ended }

    // Check attention reason first (more specific)
    switch session.attentionReason {
      case .awaitingPermission, .awaitingQuestion:
        return .attention
      case .awaitingReply:
        return .ready
      case .none:
        // Fall back to work status
        return session.workStatus == .working ? .working : .ready
    }
  }
}

// MARK: - Session Status Badge (Design System Component)

/// Unified status badge for sessions - use this everywhere for consistency
struct SessionStatusBadge: View {
  let status: SessionDisplayStatus
  var showIcon: Bool = true
  var size: BadgeSize = .regular

  enum BadgeSize {
    case mini // Just dot
    case compact // Small text only
    case regular // Icon + text
    case large // Bigger for headers

    var fontSize: CGFloat {
      switch self {
        case .mini: 0
        case .compact: 9
        case .regular: 10
        case .large: 11
      }
    }

    var iconSize: CGFloat {
      switch self {
        case .mini: 0
        case .compact: 7
        case .regular: 8
        case .large: 10
      }
    }

    var paddingH: CGFloat {
      switch self {
        case .mini: 0
        case .compact: 6
        case .regular: 8
        case .large: 10
      }
    }

    var paddingV: CGFloat {
      switch self {
        case .mini: 0
        case .compact: 2
        case .regular: 3
        case .large: 4
      }
    }
  }

  init(session: Session, showIcon: Bool = true, size: BadgeSize = .regular) {
    self.status = SessionDisplayStatus.from(session)
    self.showIcon = showIcon
    self.size = size
  }

  init(status: SessionDisplayStatus, showIcon: Bool = true, size: BadgeSize = .regular) {
    self.status = status
    self.showIcon = showIcon
    self.size = size
  }

  var body: some View {
    if size == .mini {
      // Just a colored dot
      Circle()
        .fill(status.color)
        .frame(width: 6, height: 6)
    } else {
      HStack(spacing: size == .compact ? 3 : 4) {
        if showIcon {
          Image(systemName: status.icon)
            .font(.system(size: size.iconSize, weight: .bold))
        }
        Text(status.label)
          .font(.system(size: size.fontSize, weight: .semibold))
      }
      .foregroundStyle(status.color)
      .padding(.horizontal, size.paddingH)
      .padding(.vertical, size.paddingV)
      .background(status.color.opacity(0.12), in: Capsule())
    }
  }
}

// MARK: - Session Status Dot (for indicators)

/// Status dot indicator with optional glow for working state
struct SessionStatusDot: View {
  let status: SessionDisplayStatus
  var size: CGFloat = 8
  var showGlow: Bool = true

  init(session: Session, size: CGFloat = 8, showGlow: Bool = true) {
    self.status = SessionDisplayStatus.from(session)
    self.size = size
    self.showGlow = showGlow
  }

  init(status: SessionDisplayStatus, size: CGFloat = 8, showGlow: Bool = true) {
    self.status = status
    self.size = size
    self.showGlow = showGlow
  }

  var body: some View {
    ZStack {
      // Glow ring for working status
      if showGlow, status == .working {
        Circle()
          .fill(status.color.opacity(0.2))
          .frame(width: size * 2, height: size * 2)
          .blur(radius: 3)

        Circle()
          .stroke(status.color.opacity(0.4), lineWidth: 1.5)
          .frame(width: size * 1.75, height: size * 1.75)
      }

      // Attention ring
      if showGlow, status == .attention {
        Circle()
          .stroke(status.color.opacity(0.5), lineWidth: 1.5)
          .frame(width: size * 1.75, height: size * 1.75)
      }

      // Core dot
      Circle()
        .fill(status.color)
        .frame(width: size, height: size)
        .shadow(color: status != .ended ? status.color.opacity(0.5) : .clear, radius: 3)
    }
    .frame(width: size * 2.5, height: size * 2.5)
  }
}

// MARK: - Rich Permission Banner

/// Displays contextual permission information based on tool type
struct PermissionBanner: View {
  let toolName: String
  let toolInput: String? // JSON string

  /// Parse tool input JSON and extract the most relevant display info
  private var displayInfo: (icon: String, detail: String) {
    guard let inputJson = toolInput,
          let data = inputJson.data(using: .utf8),
          let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return (toolIcon, "Accept or reject in terminal")
    }

    switch toolName {
      case "Bash":
        if let command = input["command"] as? String {
          let truncated = command.count > 60 ? String(command.prefix(57)) + "..." : command
          return ("terminal.fill", truncated)
        }
      case "Edit":
        if let filePath = input["file_path"] as? String {
          let fileName = (filePath as NSString).lastPathComponent
          return ("pencil", fileName)
        }
      case "Write":
        if let filePath = input["file_path"] as? String {
          let fileName = (filePath as NSString).lastPathComponent
          return ("doc.badge.plus", fileName)
        }
      case "Read":
        if let filePath = input["file_path"] as? String {
          let fileName = (filePath as NSString).lastPathComponent
          return ("doc.text", fileName)
        }
      case "WebFetch":
        if let url = input["url"] as? String {
          // Extract domain from URL
          if let urlObj = URL(string: url), let host = urlObj.host {
            return ("globe", host)
          }
          return ("globe", url.count > 40 ? String(url.prefix(37)) + "..." : url)
        }
      case "WebSearch":
        if let query = input["query"] as? String {
          return ("magnifyingglass", query.count > 50 ? String(query.prefix(47)) + "..." : query)
        }
      case "Glob", "Grep":
        if let pattern = input["pattern"] as? String {
          return ("magnifyingglass.circle", pattern)
        }
      case "Task":
        if let prompt = input["prompt"] as? String {
          let truncated = prompt.count > 50 ? String(prompt.prefix(47)) + "..." : prompt
          return ("person.2.fill", truncated)
        }
      case "NotebookEdit":
        if let path = input["notebook_path"] as? String {
          let fileName = (path as NSString).lastPathComponent
          return ("book.closed", fileName)
        }
      default:
        break
    }

    return (toolIcon, "Accept or reject in terminal")
  }

  private var toolIcon: String {
    switch toolName {
      case "Bash": "terminal.fill"
      case "Edit": "pencil"
      case "Write": "doc.badge.plus"
      case "Read": "doc.text"
      case "WebFetch": "globe"
      case "WebSearch": "magnifyingglass"
      case "Glob", "Grep": "magnifyingglass.circle"
      case "Task": "person.2.fill"
      case "NotebookEdit": "book.closed"
      case "AskUserQuestion": "questionmark.bubble"
      default: "gearshape"
    }
  }

  var body: some View {
    let info = displayInfo

    HStack(spacing: 12) {
      // Warning icon
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(Color.statusAttention)

      VStack(alignment: .leading, spacing: 4) {
        // Tool name header
        HStack(spacing: 6) {
          Text("Permission:")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.statusAttention)

          Text(toolName)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.primary)
        }

        // Rich detail line
        HStack(spacing: 6) {
          Image(systemName: info.icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)

          Text(info.detail)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Spacer()

      // Subtle hint
      Text("Accept in terminal")
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.tertiary)
    }
    .padding(14)
    .background(Color.statusAttention.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(Color.statusAttention.opacity(0.25), lineWidth: 1)
    )
  }
}

#Preview("Permission Banners") {
  VStack(spacing: 16) {
    PermissionBanner(
      toolName: "Bash",
      toolInput: "{\"command\": \"npm run build && npm test\"}"
    )

    PermissionBanner(
      toolName: "Edit",
      toolInput: "{\"file_path\": \"/Users/rob/project/src/ConversationView.swift\"}"
    )

    PermissionBanner(
      toolName: "Write",
      toolInput: "{\"file_path\": \"/Users/rob/project/hooks/new-feature.js\"}"
    )

    PermissionBanner(
      toolName: "WebFetch",
      toolInput: "{\"url\": \"https://api.github.com/repos/owner/name\"}"
    )

    PermissionBanner(
      toolName: "Bash",
      toolInput: nil
    )
  }
  .padding()
  .background(Color.backgroundPrimary)
}

#Preview("Status Badges") {
  VStack(alignment: .leading, spacing: 20) {
    Text("Status Badges")
      .font(.headline)

    HStack(spacing: 12) {
      SessionStatusBadge(status: .working)
      SessionStatusBadge(status: .attention)
      SessionStatusBadge(status: .ready)
      SessionStatusBadge(status: .ended)
    }

    Text("Compact Badges")
      .font(.headline)

    HStack(spacing: 12) {
      SessionStatusBadge(status: .working, size: .compact)
      SessionStatusBadge(status: .attention, size: .compact)
      SessionStatusBadge(status: .ready, size: .compact)
      SessionStatusBadge(status: .ended, size: .compact)
    }

    Text("Status Dots")
      .font(.headline)

    HStack(spacing: 20) {
      SessionStatusDot(status: .working)
      SessionStatusDot(status: .attention)
      SessionStatusDot(status: .ready)
      SessionStatusDot(status: .ended)
    }
  }
  .padding()
  .background(Color.backgroundPrimary)
}
