import ArgumentParser
import Foundation
import OrbitDockCore

@main
struct OrbitDockCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "orbitdock-cli",
    abstract: "OrbitDock hook handler for Claude Code",
    version: "1.0.0",
    subcommands: [
      SessionStartCommand.self,
      SessionEndCommand.self,
      StatusTrackerCommand.self,
      ToolTrackerCommand.self,
      SubagentTrackerCommand.self,
    ]
  )
}
