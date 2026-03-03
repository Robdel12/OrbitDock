//
//  Theme.swift
//  OrbitDock
//
//  Design system for OrbitDock
//  Dark, warm charcoal palette with subtle indigo undertones
//  Engineered for readability and professional clarity
//

import SwiftUI

// MARK: - Design Tokens

/// 4pt-base spacing scale — replaces ad-hoc pixel values across the app.
enum Spacing {
  static let xxs: CGFloat = 2
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 24
  static let xxl: CGFloat = 32
  static let section: CGFloat = 20
}

/// Canonical font sizes — clear visual hierarchy with distinct steps.
enum TypeScale {
  static let micro: CGFloat = 10
  static let caption: CGFloat = 12
  static let body: CGFloat = 13
  static let label: CGFloat = 12
  static let code: CGFloat = 13
  static let subhead: CGFloat = 14
  static let title: CGFloat = 15
  /// Content meant to be read (user prompts, steer text) vs. UI labels
  static let reading: CGFloat = 15
  /// Conversation timeline role labels ("Assistant", "You", "Reasoning")
  static let chatLabel: CGFloat = 12
  /// Assistant/user prose body in transcript cards
  static let chatBody: CGFloat = 15
  /// Prominent markdown headers inside assistant responses
  static let chatHeading1: CGFloat = 24
  static let chatHeading2: CGFloat = 20
  static let chatHeading3: CGFloat = 16
  /// Thinking-mode heading 1 — scaled down from chatHeading1 but still dominant
  static let thinkingHeading1: CGFloat = 18
  /// Thinking-mode heading 2 — clear step below thinkingHeading1
  static let thinkingHeading2: CGFloat = 16
  /// Inline and block code inside assistant responses
  static let chatCode: CGFloat = 14
  /// Section headers ("Active Agents") — dominant dashboard tier
  static let headline: CGFloat = 22
  /// Project names, emphasized subheads
  static let large: CGFloat = 16
}

/// Corner radius tiers — replaces ad-hoc 4/5/6/8/10/12 mix.
enum Radius {
  static let sm: CGFloat = 4
  static let md: CGFloat = 6
  static let lg: CGFloat = 10
  static let xl: CGFloat = 14
}

/// Opacity tiers — collapses 17+ unique values to 6 semantic levels.
enum OpacityTier {
  static let tint: Double = 0.04
  static let subtle: Double = 0.08
  static let light: Double = 0.12
  static let medium: Double = 0.20
  static let strong: Double = 0.40
  static let vivid: Double = 0.70
}

/// Standard left-edge accent bar width (was 2px/3px/4px mix).
enum EdgeBar {
  static let width: CGFloat = 3
}

// MARK: - Design System

extension Color {

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Brand

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Primary brand color — calmer teal, less neon
  static let accent = Color(red: 0.33, green: 0.68, blue: 0.90)

  /// Slightly brighter for glow effects
  static let accentGlow = Color(red: 0.35, green: 0.8, blue: 0.98)

  /// Muted accent for subtle highlights
  static let accentMuted = Color(red: 0.2, green: 0.5, blue: 0.6)

  /// Alias for backwards compatibility
  static let accentPrimary = accent

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Diff Colors

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Line background washes
  static let diffAddedBg = Color(red: 0.12, green: 0.26, blue: 0.15).opacity(0.30)
  static let diffRemovedBg = Color(red: 0.30, green: 0.12, blue: 0.12).opacity(0.30)

  /// Prefix / text accent colors
  static let diffAddedAccent = Color(red: 0.4, green: 0.95, blue: 0.5)
  static let diffRemovedAccent = Color(red: 1.0, green: 0.5, blue: 0.5)

  /// Left edge bar colors (saturated, opaque)
  static let diffAddedEdge = Color(red: 0.3, green: 0.78, blue: 0.4)
  static let diffRemovedEdge = Color(red: 0.85, green: 0.35, blue: 0.35)

  /// Word-level inline highlights (softer: 0.25 down from 0.35)
  static let diffAddedHighlight = Color(red: 0.4, green: 0.95, blue: 0.5).opacity(0.25)
  static let diffRemovedHighlight = Color(red: 1.0, green: 0.5, blue: 0.5).opacity(0.25)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Backgrounds — Warm Charcoal with Subtle Indigo

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Main content area — warm charcoal
  static let backgroundPrimary = Color(red: 0.06, green: 0.058, blue: 0.065)

  /// Elevated surfaces (sidebars, headers)
  static let backgroundSecondary = Color(red: 0.082, green: 0.08, blue: 0.09)

  /// Cards, code blocks — warm card surface
  static let backgroundTertiary = Color(red: 0.11, green: 0.108, blue: 0.125)

  /// Slide-in panels — subtle indigo cast
  static let panelBackground = Color(red: 0.055, green: 0.055, blue: 0.072)

  /// Panel borders — subtle accent tint
  static let panelBorder = accent.opacity(0.1)

  /// Code blocks — slightly darker
  static let backgroundCode = Color(red: 0.04, green: 0.04, blue: 0.052)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Surfaces — Interaction States

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let surfaceHover = accent.opacity(0.06)
  static let surfaceSelected = accent.opacity(0.12)
  static let surfaceBorder = accent.opacity(0.10)
  static let surfaceActive = accent.opacity(0.20)

  /// Row highlight
  static let rowHighlight = Color(red: 0.15, green: 0.18, blue: 0.28).opacity(0.35)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Text Hierarchy — Guaranteed Readable on Dark Backgrounds

  //
  // NEVER use SwiftUI's `.foregroundStyle(.tertiary)` or `.quaternary` —
  // they resolve to ~30%/~20% opacity which is invisible on our dark theme.
  // Always use these explicit Color values instead.
  //
  // Usage guide:
  //   .textPrimary   → headings, session names, key data values
  //   .textSecondary  → labels, supporting text, active descriptions
  //   .textTertiary   → meta info, timestamps, counts, monospaced data
  //   .textQuaternary → lowest priority but still readable (hints, divider text)
  //
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let textPrimary = Color.white.opacity(0.92)
  static let textSecondary = Color.white.opacity(0.65)
  static let textTertiary = Color.white.opacity(0.50)
  static let textQuaternary = Color.white.opacity(0.38)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Provider Colors

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let providerClaude = accent
  static let providerCodex = Color(red: 0.29, green: 0.78, blue: 0.56)
  static let providerGemini = Color(red: 0.4, green: 0.5, blue: 0.9)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Status Indicators

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  //
  // 5 distinct status states:
  // 1. Permission (coral) - Needs tool approval - URGENT
  // 2. Question (purple)  - Claude asked you something - URGENT
  // 3. Working (teal)     - Actively processing
  // 4. Reply (soft blue)  - Awaiting your next prompt
  // 5. Ended (warm gray)  - Session finished
  //

  /// Active/Working — brand teal
  static let statusWorking = accent

  /// Permission required — softened coral
  static let statusPermission = Color(red: 0.95, green: 0.55, blue: 0.42)

  /// Question waiting — purple
  static let statusQuestion = Color(red: 0.75, green: 0.5, blue: 0.95)

  /// Awaiting reply — soft blue
  static let statusReply = Color(red: 0.45, green: 0.7, blue: 1.0)

  /// Error — red warning
  static let statusError = Color(red: 0.95, green: 0.4, blue: 0.45)

  /// Ended/Idle — warm gray, less purple
  static let statusEnded = Color(red: 0.42, green: 0.40, blue: 0.45)

  /// Legacy aliases for backward compatibility
  /// @deprecated Use statusPermission or statusQuestion instead
  static let statusAttention = statusPermission
  /// @deprecated Use statusReply instead
  static let statusReady = statusReply
  /// @deprecated Use statusReply instead
  static let statusWaiting = statusReply
  /// @deprecated Use statusReply instead
  static let statusSuccess = statusReply
  /// @deprecated Use statusEnded instead
  static let statusIdle = statusEnded

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Model Colors

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let modelOpus = Color(red: 0.7, green: 0.45, blue: 0.95)
  static let modelSonnet = Color(red: 0.4, green: 0.65, blue: 1.0)
  static let modelHaiku = Color(red: 0.3, green: 0.85, blue: 0.8)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Tool Colors

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let toolRead = Color(red: 0.45, green: 0.7, blue: 1.0)
  static let toolWrite = Color(red: 1.0, green: 0.6, blue: 0.3)
  static let toolBash = Color(red: 0.35, green: 0.85, blue: 0.55)
  static let toolSearch = Color(red: 0.65, green: 0.5, blue: 0.95)
  static let toolTask = Color(red: 0.5, green: 0.55, blue: 1.0)
  static let toolWeb = accent
  static let toolQuestion = Color(red: 1.0, green: 0.7, blue: 0.3)
  static let toolMcp = Color(red: 0.55, green: 0.7, blue: 0.85)
  static let toolSkill = Color(red: 0.85, green: 0.55, blue: 0.9)
  static let toolPlan = Color(red: 0.4, green: 0.75, blue: 0.55)
  static let toolTodo = Color(red: 0.7, green: 0.8, blue: 0.45)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: MCP Server Colors

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let serverGitHub = Color(red: 0.6, green: 0.5, blue: 1.0)
  static let serverLinear = Color(red: 0.4, green: 0.55, blue: 1.0)
  static let serverChrome = Color(red: 1.0, green: 0.65, blue: 0.25)
  static let serverSlack = Color(red: 0.95, green: 0.4, blue: 0.6)
  static let serverApple = Color(red: 0.45, green: 0.75, blue: 1.0)
  static let serverDefault = accentMuted

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Syntax Highlighting

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let syntaxKeyword = Color(red: 0.75, green: 0.5, blue: 0.95)
  static let syntaxString = Color(red: 0.95, green: 0.65, blue: 0.4)
  static let syntaxNumber = Color(red: 0.7, green: 0.85, blue: 0.5)
  static let syntaxComment = Color(red: 0.4, green: 0.45, blue: 0.5)
  static let syntaxType = accent
  static let syntaxFunction = Color(red: 0.9, green: 0.85, blue: 0.55)
  static let syntaxProperty = Color(red: 0.55, green: 0.75, blue: 0.95)
  static let syntaxText = Color(red: 0.85, green: 0.87, blue: 0.9)

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
  // MARK: Git / Branch

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let gitBranch = Color(red: 0.95, green: 0.65, blue: 0.3)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Terminal

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let terminal = Color(red: 0.35, green: 0.85, blue: 0.55)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Effects

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Subtle glow for active states
  static let orbitGlow = accent.opacity(0.3)

  /// Attention pulse color
  static let beaconPulse = statusPermission

  /// Legacy — consolidated to backgroundPrimary variants
  static let nebulaStart = Color(red: 0.20, green: 0.13, blue: 0.30)
  static let nebulaEnd = Color(red: 0.08, green: 0.12, blue: 0.28)
  static let starlight = Color.white.opacity(0.85)
  static let voidBlack = Color(red: 0.02, green: 0.02, blue: 0.04)

  /// Ready state
  static let statusDocked = accent

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Composer Border — Input Mode Colors

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Prompt mode border
  static let composerPrompt = accent
  /// Steer mode border
  static let composerSteer = toolWrite
  /// Review mode border
  static let composerReview = statusQuestion
  /// Shell mode border
  static let composerShell = shellAccent

  /// Terminal green accent for user-initiated shell commands
  static let shellAccent = Color(red: 0.3, green: 0.85, blue: 0.4)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Autonomy Levels — Risk Spectrum

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  /// Locked — most restrictive
  static let autonomyLocked = Color(red: 0.2, green: 0.75, blue: 0.78)
  /// Guarded
  static let autonomyGuarded = accent
  /// Autonomous — Codex default
  static let autonomyAutonomous = Color(red: 0.35, green: 0.82, blue: 0.55)
  /// Open — caution
  static let autonomyOpen = Color(red: 0.95, green: 0.75, blue: 0.3)
  /// Full Auto
  static let autonomyFullAuto = Color(red: 1.0, green: 0.6, blue: 0.3)
  /// Unrestricted — max risk
  static let autonomyUnrestricted = Color(red: 1.0, green: 0.45, blue: 0.4)

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  // MARK: Effort Levels

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  static let effortNone = Color(red: 0.42, green: 0.40, blue: 0.45)
  static let effortMinimal = Color(red: 0.2, green: 0.75, blue: 0.78)
  static let effortLow = accent
  static let effortMedium = Color(red: 0.35, green: 0.82, blue: 0.55)
  static let effortHigh = Color(red: 0.95, green: 0.75, blue: 0.3)
  static let effortXHigh = Color(red: 1.0, green: 0.55, blue: 0.35)
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
/// 5 distinct states for maximum visual clarity
enum SessionDisplayStatus {
  case working // Claude actively processing (cyan)
  case permission // Needs tool approval (coral) - URGENT
  case question // Claude asked you something (purple) - URGENT
  case reply // Awaiting your next prompt (soft blue)
  case ended // Session finished (muted gray)

  var color: Color {
    switch self {
      case .working: .statusWorking
      case .permission: .statusPermission
      case .question: .statusQuestion
      case .reply: .statusReply
      case .ended: .statusEnded
    }
  }

  var label: String {
    switch self {
      case .working: "Working"
      case .permission: "Permission"
      case .question: "Question"
      case .reply: "Ready"
      case .ended: "Ended"
    }
  }

  var icon: String {
    switch self {
      case .working: "bolt.fill"
      case .permission: "lock.fill"
      case .question: "questionmark.bubble.fill"
      case .reply: "bubble.left"
      case .ended: "moon.fill"
    }
  }

  /// Whether this status requires user attention (shows in attention count)
  var needsAttention: Bool {
    switch self {
      case .permission, .question: true
      default: false
    }
  }

  /// Create from Session model
  static func from(_ session: Session) -> SessionDisplayStatus {
    guard session.isActive else { return .ended }

    // Check attention reason first (more specific)
    switch session.attentionReason {
      case .awaitingPermission:
        return .permission
      case .awaitingQuestion:
        return .question
      case .awaitingReply:
        return .reply
      case .none:
        // Fall back to work status
        return session.workStatus == .working ? .working : .reply
    }
  }

  // Legacy support
  static let attention = permission
  static let ready = reply
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

/// Status dot indicator with optional glow for active states
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
    Circle()
      .fill(status.color)
      .frame(width: size, height: size)
      .shadow(
        color: showGlow && status != .ended ? status.color.opacity(0.4) : .clear,
        radius: 4
      )
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
        if let command = String.shellCommandDisplay(from: input["command"])
          ?? String.shellCommandDisplay(from: input["cmd"])
        {
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
        .foregroundStyle(Color.textTertiary)
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
      toolInput: "{\"file_path\": \"/Users/developer/project/src/ConversationView.swift\"}"
    )

    PermissionBanner(
      toolName: "Write",
      toolInput: "{\"file_path\": \"/Users/developer/project/hooks/new-feature.js\"}"
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
    Text("5-State Status System")
      .font(.headline)

    HStack(spacing: 12) {
      SessionStatusBadge(status: .working)
      SessionStatusBadge(status: .permission)
      SessionStatusBadge(status: .question)
      SessionStatusBadge(status: .reply)
      SessionStatusBadge(status: .ended)
    }

    Text("Compact Badges")
      .font(.headline)

    HStack(spacing: 12) {
      SessionStatusBadge(status: .working, size: .compact)
      SessionStatusBadge(status: .permission, size: .compact)
      SessionStatusBadge(status: .question, size: .compact)
      SessionStatusBadge(status: .reply, size: .compact)
      SessionStatusBadge(status: .ended, size: .compact)
    }

    Text("Status Dots")
      .font(.headline)

    HStack(spacing: 20) {
      SessionStatusDot(status: .working)
      SessionStatusDot(status: .permission)
      SessionStatusDot(status: .question)
      SessionStatusDot(status: .reply)
      SessionStatusDot(status: .ended)
    }
  }
  .padding()
  .background(Color.backgroundPrimary)
}
