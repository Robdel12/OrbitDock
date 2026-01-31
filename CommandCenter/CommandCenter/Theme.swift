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
    // MARK: Status - Mission Control Indicators
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Active/Working - Cyan orbit (session in flight)
    static let statusWorking = accent

    /// Waiting for input - Amber beacon
    static let statusWaiting = Color(red: 1.0, green: 0.7, blue: 0.25)

    /// Permission required - Yellow alert
    static let statusPermission = Color(red: 1.0, green: 0.85, blue: 0.35)

    /// Error - Red warning
    static let statusError = Color(red: 0.95, green: 0.4, blue: 0.45)

    /// Success/Complete - Soft green confirmation
    static let statusSuccess = Color(red: 0.35, green: 0.85, blue: 0.55)

    /// Idle/Ended - Dimmed
    static let statusIdle = Color.white.opacity(0.25)

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: Model Colors - Crew Ranks
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    static let modelOpus = Color(red: 0.7, green: 0.45, blue: 0.95)         // Cosmic purple
    static let modelSonnet = Color(red: 0.4, green: 0.65, blue: 1.0)        // Nebula blue
    static let modelHaiku = Color(red: 0.3, green: 0.85, blue: 0.8)         // Aqua teal

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: Tool Colors - Operations Palette
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    static let toolRead = Color(red: 0.45, green: 0.7, blue: 1.0)           // Scanner blue
    static let toolWrite = Color(red: 1.0, green: 0.6, blue: 0.3)           // Thruster orange
    static let toolBash = Color(red: 0.35, green: 0.85, blue: 0.55)         // Terminal green
    static let toolSearch = Color(red: 0.65, green: 0.5, blue: 0.95)        // Radar purple
    static let toolTask = Color(red: 0.5, green: 0.55, blue: 1.0)           // Subspace indigo
    static let toolWeb = accent                                              // Uses brand cyan
    static let toolQuestion = Color(red: 1.0, green: 0.7, blue: 0.3)        // Beacon amber
    static let toolMcp = Color(red: 0.55, green: 0.7, blue: 0.85)           // Dock gray-blue
    static let toolSkill = Color(red: 0.85, green: 0.55, blue: 0.9)         // Warp pink
    static let toolPlan = Color(red: 0.4, green: 0.75, blue: 0.55)          // Navigate green
    static let toolTodo = Color(red: 0.7, green: 0.8, blue: 0.45)           // Manifest lime

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: MCP Server Colors - Docked Services
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    static let serverGitHub = Color(red: 0.6, green: 0.5, blue: 1.0)        // Nebula purple
    static let serverLinear = Color(red: 0.4, green: 0.55, blue: 1.0)       // Deep blue
    static let serverChrome = Color(red: 1.0, green: 0.65, blue: 0.25)      // Solar orange
    static let serverSlack = Color(red: 0.95, green: 0.4, blue: 0.6)        // Nova pink
    static let serverApple = Color(red: 0.45, green: 0.75, blue: 1.0)       // Sky blue
    static let serverDefault = accentMuted                                   // Uses muted accent

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: Syntax Highlighting - Code Telescope
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    static let syntaxKeyword = Color(red: 0.75, green: 0.5, blue: 0.95)     // Nebula purple
    static let syntaxString = Color(red: 0.95, green: 0.65, blue: 0.4)      // Solar orange
    static let syntaxNumber = Color(red: 0.7, green: 0.85, blue: 0.5)       // Starchart lime
    static let syntaxComment = Color(red: 0.4, green: 0.45, blue: 0.5)      // Distant star gray
    static let syntaxType = accent                                           // Orbit cyan
    static let syntaxFunction = Color(red: 0.9, green: 0.85, blue: 0.55)    // Signal yellow
    static let syntaxProperty = Color(red: 0.55, green: 0.75, blue: 0.95)   // Atmosphere blue
    static let syntaxText = Color(red: 0.85, green: 0.87, blue: 0.9)        // Starlight

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: Language Badge Colors
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    static let langSwift = Color(red: 1.0, green: 0.55, blue: 0.3)          // Orange
    static let langJavaScript = Color(red: 0.95, green: 0.85, blue: 0.4)    // Yellow
    static let langPython = Color(red: 0.4, green: 0.65, blue: 1.0)         // Blue
    static let langRuby = Color(red: 0.95, green: 0.4, blue: 0.4)           // Red
    static let langGo = accent                                               // Cyan (brand!)
    static let langRust = Color(red: 0.95, green: 0.55, blue: 0.3)          // Orange
    static let langBash = Color(red: 0.35, green: 0.85, blue: 0.55)         // Green
    static let langJSON = Color(red: 0.7, green: 0.5, blue: 0.95)           // Purple
    static let langHTML = Color(red: 0.95, green: 0.45, blue: 0.4)          // Red
    static let langCSS = Color(red: 0.4, green: 0.55, blue: 1.0)            // Blue
    static let langSQL = accent                                              // Cyan (brand!)

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: Markdown Theme
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    static let markdownInlineCode = Color(red: 0.95, green: 0.7, blue: 0.45)    // Warm signal
    static let markdownLink = accent                                             // Orbit cyan links!
    static let markdownBlockquote = Color(red: 0.6, green: 0.5, blue: 0.9)      // Nebula purple

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: Git / Branch - Navigation
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    static let gitBranch = Color(red: 0.95, green: 0.65, blue: 0.3)             // Flight path orange

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: Terminal - Uplink
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    static let terminal = Color(red: 0.35, green: 0.85, blue: 0.55)             // Uplink green

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
