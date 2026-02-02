# Contributing to OrbitDock

Thanks for your interest in contributing!

## Building Locally

1. Open `CommandCenter/CommandCenter.xcodeproj` in Xcode
2. Select your team in **Signing & Capabilities** (or choose "Sign to Run Locally" for a personal team)
3. Build and run (⌘R)

The app requires macOS 14+.

## Project Structure

```
CommandCenter/
├── CommandCenter/          # Main SwiftUI app
│   ├── Views/              # UI components
│   ├── Services/           # Business logic
│   └── Models/             # Data models
├── OrbitDockCore/          # Swift Package (shared code + CLI)
│   └── Sources/
│       ├── OrbitDockCore/  # Database, Git ops, Models
│       └── OrbitDockCLI/   # CLI tool (hooks into Claude Code)
└── Scripts/                # Build scripts
```

## Testing Changes

1. Build the app in Xcode
2. Start a Claude Code session to trigger the CLI hooks
3. Verify your changes in OrbitDock

## Code Style

- SwiftUI with modern macOS 14+ APIs
- Prefer `@State` with dictionaries keyed by ID for session-specific state
- Use the cosmic theme colors from `Theme.swift` (not system colors)
- Run SwiftFormat before committing

## Submitting Changes

1. Fork the repo
2. Create a feature branch
3. Make your changes
4. Open a PR with a clear description
