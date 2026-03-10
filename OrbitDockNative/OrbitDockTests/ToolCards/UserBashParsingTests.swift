import Foundation
@testable import OrbitDock
import Testing

struct UserBashParsingTests {
  @Test func parsedSystemContextReadsAgentsInstructionsBody() {
    let content = """
    # AGENTS.md instructions for /tmp/demo
    <INSTRUCTIONS>
    Use the repo root.
    Keep tests green.
    </INSTRUCTIONS>
    """

    let parsed = ParsedSystemContext.parse(from: content)

    #expect(parsed?.label == "AGENTS.md · demo")
    #expect(parsed?.icon == "doc.text")
    #expect(parsed?.body == "Use the repo root.\nKeep tests green.")
  }

  @Test func parsedBashContentNormalizesInputAndRetainsOutput() {
    let content = """
    <bash-input>/bin/zsh -lc "git status"</bash-input>
    <bash-stdout>On branch main</bash-stdout>
    """

    let parsed = ParsedBashContent.parse(from: content)

    #expect(parsed?.input == "git status")
    #expect(parsed?.stdout == "On branch main")
    #expect(parsed?.stderr == "")
    #expect(parsed?.hasInput == true)
    #expect(parsed?.hasOutput == true)
  }

  @Test func parsedSlashCommandRequiresNameOrOutput() {
    let commandOnlyOutput = """
    <local-command-stdout>Downloaded skill bundle</local-command-stdout>
    """

    let commandWithArgs = """
    <command-name>/rename</command-name>
    <command-message>rename</command-message>
    <command-args>Design system pass</command-args>
    """

    #expect(ParsedSlashCommand.parse(from: commandOnlyOutput)?.stdout == "Downloaded skill bundle")
    #expect(ParsedSlashCommand.parse(from: commandWithArgs)?.name == "/rename")
    #expect(ParsedSlashCommand.parse(from: commandWithArgs)?.hasArgs == true)
  }

  @Test func parsedShellContextBuildsBlocksAndExitCodes() {
    let content = """
    <shell-context>
    $ git status
    On branch main

    $ npm test
    failed
    (exit 1)
    </shell-context>
    Please summarize the issue.
    """

    let parsed = ParsedShellContext.parse(from: content)

    #expect(parsed?.commandCount == 2)
    #expect(parsed?.commands.first?.command == "git status")
    #expect(parsed?.commands.first?.output == "On branch main")
    #expect(parsed?.commands.first?.exitCode == nil)
    #expect(parsed?.commands.last?.command == "npm test")
    #expect(parsed?.commands.last?.output == "failed")
    #expect(parsed?.commands.last?.exitCode == 1)
    #expect(parsed?.commands.last?.hasError == true)
    #expect(parsed?.userPrompt == "Please summarize the issue.")
  }
}
