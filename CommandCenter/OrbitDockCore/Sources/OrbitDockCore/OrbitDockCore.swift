// OrbitDockCore - Shared library for OrbitDock CLI and App
//
// This package provides:
// - CLIDatabase: Lightweight SQLite wrapper with WAL mode
// - Session/Workstream operations
// - Git utilities for branch detection
// - Input models for Claude Code hooks

// Re-export all public types
@_exported import struct Foundation.Date
@_exported import struct Foundation.URL

// Database
public typealias Database = CLIDatabase

// Git
public typealias Git = GitOperations
