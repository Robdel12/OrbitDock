//
//  Theme.swift
//  CommandCenter
//
//  Design system inspired by Linear/Raycast + VS Code
//

import SwiftUI

// MARK: - Dark Theme Colors

extension Color {
    // Backgrounds - refined dark palette
    static let backgroundPrimary = Color(red: 0.067, green: 0.067, blue: 0.075)   // Deep charcoal
    static let backgroundSecondary = Color(red: 0.09, green: 0.09, blue: 0.10)    // Elevated
    static let backgroundTertiary = Color(red: 0.12, green: 0.12, blue: 0.13)     // Cards/code blocks

    // Panels - for slide-in panels
    static let panelBackground = Color(red: 0.085, green: 0.085, blue: 0.095)
    static let panelBorder = Color.white.opacity(0.05)

    // Surfaces - subtle interaction states
    static let surfaceHover = Color.white.opacity(0.03)
    static let surfaceSelected = Color.white.opacity(0.06)
    static let surfaceBorder = Color.white.opacity(0.06)
    static let surfaceActive = Color.white.opacity(0.10)

    // Text - clear hierarchy
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)
    static let textQuaternary = Color.white.opacity(0.20)

    // Status colors (semantic) - slightly muted, professional
    static let statusWorking = Color(red: 0.3, green: 0.85, blue: 0.5)    // Soft green
    static let statusWaiting = Color(red: 1.0, green: 0.6, blue: 0.2)     // Warm orange
    static let statusPermission = Color(red: 1.0, green: 0.82, blue: 0.3) // Soft yellow
    static let statusIdle = Color.secondary

    // Model colors - distinctive but not harsh
    static let modelOpus = Color(red: 0.7, green: 0.4, blue: 0.9)         // Soft purple
    static let modelSonnet = Color(red: 0.4, green: 0.6, blue: 1.0)       // Soft blue
    static let modelHaiku = Color(red: 0.3, green: 0.8, blue: 0.75)       // Soft teal

    // Accent - for primary actions
    static let accentPrimary = Color(red: 0.4, green: 0.55, blue: 1.0)    // Soft blue
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
