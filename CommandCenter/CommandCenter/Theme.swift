//
//  Theme.swift
//  CommandCenter
//

import SwiftUI

// MARK: - Dark Theme Colors

extension Color {
    // Backgrounds - true dark
    static let backgroundPrimary = Color(red: 0.08, green: 0.08, blue: 0.09)    // Near black
    static let backgroundSecondary = Color(red: 0.11, green: 0.11, blue: 0.12)  // Slightly lighter
    static let backgroundTertiary = Color(red: 0.14, green: 0.14, blue: 0.15)   // Cards/elevated

    // Surfaces
    static let surfaceHover = Color.white.opacity(0.04)
    static let surfaceSelected = Color.white.opacity(0.08)
    static let surfaceBorder = Color.white.opacity(0.08)

    // Text
    static let textPrimary = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.6)
    static let textTertiary = Color.white.opacity(0.4)
    static let textQuaternary = Color.white.opacity(0.25)
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
