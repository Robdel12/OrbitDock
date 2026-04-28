use crate::domain_events::{ToolFamily, ToolKind, ToolStatus};

pub fn classify_tool_name(name: &str) -> (ToolFamily, ToolKind) {
  match name {
    "Bash" | "bash" => (ToolFamily::Shell, ToolKind::Bash),
    "Read" | "read" | "FileRead" => (ToolFamily::FileRead, ToolKind::Read),
    "Edit" | "edit" | "FileEdit" | "MultiEdit" => (ToolFamily::FileChange, ToolKind::Edit),
    "Write" | "write" | "FileWrite" => (ToolFamily::FileChange, ToolKind::Write),
    "NotebookEdit" => (ToolFamily::FileChange, ToolKind::NotebookEdit),
    "Glob" | "glob" => (ToolFamily::Search, ToolKind::Glob),
    "Grep" | "grep" => (ToolFamily::Search, ToolKind::Grep),
    "ToolSearch" => (ToolFamily::Search, ToolKind::ToolSearch),
    "WebSearch" | "websearch" => (ToolFamily::Web, ToolKind::WebSearch),
    "WebFetch" | "webfetch" => (ToolFamily::Web, ToolKind::WebFetch),
    "Agent" | "agent" | "task" => (ToolFamily::Agent, ToolKind::SpawnAgent),
    "AskUserQuestion" => (ToolFamily::Question, ToolKind::AskUserQuestion),
    "EnterPlanMode" => (ToolFamily::Plan, ToolKind::EnterPlanMode),
    "ExitPlanMode" => (ToolFamily::Plan, ToolKind::ExitPlanMode),
    "UpdatePlan" => (ToolFamily::Plan, ToolKind::UpdatePlan),
    "TodoWrite" | "todo_write" => (ToolFamily::Todo, ToolKind::TodoWrite),
    "CompactContext" => (ToolFamily::Context, ToolKind::CompactContext),
    "Config" => (ToolFamily::Generic, ToolKind::Config),
    "EnterWorktree" => (ToolFamily::Generic, ToolKind::EnterWorktree),
    "ViewImage" | "view_image" => (ToolFamily::Image, ToolKind::ViewImage),
    "ImageGeneration" => (ToolFamily::Image, ToolKind::ImageGeneration),
    "HookNotification" => (ToolFamily::Hook, ToolKind::HookNotification),
    "HandoffRequested" => (ToolFamily::Agent, ToolKind::HandoffRequested),
    name if name.starts_with("mcp__") => (ToolFamily::Mcp, ToolKind::McpToolCall),
    _ => (ToolFamily::Generic, ToolKind::Generic),
  }
}

pub(super) fn glyph_for_kind(kind: ToolKind, family: ToolFamily) -> (String, String) {
  match kind {
    ToolKind::Bash => ("terminal".into(), "toolBash".into()),
    ToolKind::Read => ("doc.plaintext".into(), "toolRead".into()),
    ToolKind::Edit => ("pencil.line".into(), "toolWrite".into()),
    ToolKind::Write => {
      if family == ToolFamily::Plan {
        ("map".into(), "toolPlan".into())
      } else {
        ("pencil.line".into(), "toolWrite".into())
      }
    }
    ToolKind::NotebookEdit => ("pencil.line".into(), "toolWrite".into()),
    ToolKind::Glob | ToolKind::Grep | ToolKind::ToolSearch => {
      ("magnifyingglass".into(), "toolSearch".into())
    }
    ToolKind::WebSearch | ToolKind::WebFetch => ("globe".into(), "toolWeb".into()),
    ToolKind::McpToolCall | ToolKind::ReadMcpResource | ToolKind::ListMcpResources => {
      ("puzzlepiece.extension".into(), "toolMcp".into())
    }
    ToolKind::DynamicToolCall => ("wrench.and.screwdriver".into(), "toolTask".into()),
    ToolKind::SpawnAgent
    | ToolKind::SendAgentInput
    | ToolKind::ResumeAgent
    | ToolKind::WaitAgent
    | ToolKind::CloseAgent
    | ToolKind::TaskOutput
    | ToolKind::TaskStop => ("bolt.fill".into(), "toolTask".into()),
    ToolKind::AskUserQuestion => ("questionmark.bubble".into(), "toolQuestion".into()),
    ToolKind::GuardianAssessment => ("shield.lefthalf.filled".into(), "feedbackCaution".into()),
    ToolKind::EnterPlanMode | ToolKind::ExitPlanMode | ToolKind::UpdatePlan => {
      ("map".into(), "toolPlan".into())
    }
    ToolKind::TodoWrite => ("checklist".into(), "toolTodo".into()),
    ToolKind::CompactContext => ("arrow.triangle.2.circlepath".into(), "accent".into()),
    ToolKind::ViewImage => ("photo".into(), "toolRead".into()),
    ToolKind::ImageGeneration => ("sparkles".into(), "accent".into()),
    ToolKind::HookNotification => ("bolt.badge.clock".into(), "feedbackCaution".into()),
    ToolKind::HandoffRequested => ("arrow.triangle.branch".into(), "statusReply".into()),
    _ => match family {
      ToolFamily::Shell => ("terminal".into(), "toolBash".into()),
      ToolFamily::FileRead => ("doc.plaintext".into(), "toolRead".into()),
      ToolFamily::FileChange => ("pencil.line".into(), "toolWrite".into()),
      ToolFamily::Search => ("magnifyingglass".into(), "toolSearch".into()),
      ToolFamily::Web => ("globe".into(), "toolWeb".into()),
      ToolFamily::Agent => ("bolt.fill".into(), "toolTask".into()),
      ToolFamily::Mcp => ("puzzlepiece.extension".into(), "toolMcp".into()),
      ToolFamily::Hook => ("bolt.badge.clock".into(), "feedbackCaution".into()),
      _ => ("gearshape".into(), "secondaryLabel".into()),
    },
  }
}

pub(super) fn display_name_for_kind(kind: ToolKind, family: ToolFamily, title: &str) -> String {
  match kind {
    ToolKind::Bash => "Bash".into(),
    ToolKind::Read => "Read".into(),
    ToolKind::Edit => "Edit".into(),
    ToolKind::Write => {
      if family == ToolFamily::Plan {
        "Plan".into()
      } else {
        "Write".into()
      }
    }
    ToolKind::NotebookEdit => "Notebook Edit".into(),
    ToolKind::Glob => "Glob".into(),
    ToolKind::Grep => "Grep".into(),
    ToolKind::ToolSearch => "Tool Search".into(),
    ToolKind::WebSearch => "Web Search".into(),
    ToolKind::WebFetch => "Web Fetch".into(),
    ToolKind::McpToolCall => {
      if title.is_empty() {
        "MCP Tool".into()
      } else {
        title.to_string()
      }
    }
    ToolKind::DynamicToolCall => {
      if title.is_empty() {
        "Dynamic Tool".into()
      } else {
        title.to_string()
      }
    }
    ToolKind::SpawnAgent => "Agent".into(),
    ToolKind::AskUserQuestion => "Question".into(),
    ToolKind::GuardianAssessment => "Auto-review".into(),
    ToolKind::EnterPlanMode => "Plan Mode".into(),
    ToolKind::ExitPlanMode => "Exit Plan".into(),
    ToolKind::TodoWrite => "Todo".into(),
    ToolKind::CompactContext => "Compacting Context".into(),
    ToolKind::ViewImage => "View Image".into(),
    ToolKind::HookNotification => "Hook".into(),
    ToolKind::HandoffRequested => "Handoff".into(),
    _ => {
      if title.is_empty() {
        "Tool".into()
      } else {
        title.to_string()
      }
    }
  }
}

pub(super) fn tool_type_string(kind: ToolKind, family: ToolFamily) -> String {
  if family == ToolFamily::Plan && kind == ToolKind::Write {
    return "plan".to_string();
  }
  match kind {
    ToolKind::Bash => "bash",
    ToolKind::Read => "read",
    ToolKind::Edit | ToolKind::NotebookEdit => "edit",
    ToolKind::Write => "write",
    ToolKind::Glob => "glob",
    ToolKind::Grep => "grep",
    ToolKind::SpawnAgent
    | ToolKind::SendAgentInput
    | ToolKind::ResumeAgent
    | ToolKind::WaitAgent
    | ToolKind::CloseAgent
    | ToolKind::TaskOutput
    | ToolKind::TaskStop => "task",
    ToolKind::McpToolCall | ToolKind::ReadMcpResource | ToolKind::ListMcpResources => "mcp",
    ToolKind::DynamicToolCall => "dynamicTool",
    ToolKind::WebSearch => "webSearch",
    ToolKind::WebFetch => "webFetch",
    ToolKind::GuardianAssessment => "guardianAssessment",
    ToolKind::EnterPlanMode | ToolKind::ExitPlanMode | ToolKind::UpdatePlan => "plan",
    ToolKind::TodoWrite => "todo",
    ToolKind::AskUserQuestion => "question",
    ToolKind::ToolSearch => "toolSearch",
    ToolKind::HookNotification => "hook",
    ToolKind::HandoffRequested => "handoff",
    ToolKind::ViewImage | ToolKind::ImageGeneration => "image",
    ToolKind::CompactContext => "compactContext",
    ToolKind::Config => "config",
    ToolKind::EnterWorktree => "worktree",
    _ => "generic",
  }
  .to_string()
}

pub(super) fn display_tier_string(
  kind: ToolKind,
  _family: ToolFamily,
  _status: ToolStatus,
) -> String {
  match kind {
    ToolKind::AskUserQuestion | ToolKind::GuardianAssessment => "prominent",
    ToolKind::Bash | ToolKind::Edit | ToolKind::Write | ToolKind::NotebookEdit => "standard",
    ToolKind::SpawnAgent | ToolKind::HandoffRequested => "standard",
    ToolKind::McpToolCall | ToolKind::DynamicToolCall => "standard",
    ToolKind::WebSearch | ToolKind::WebFetch => "standard",
    ToolKind::Read | ToolKind::Glob | ToolKind::Grep | ToolKind::ToolSearch => "compact",
    ToolKind::EnterPlanMode
    | ToolKind::ExitPlanMode
    | ToolKind::UpdatePlan
    | ToolKind::TodoWrite
    | ToolKind::CompactContext
    | ToolKind::HookNotification
    | ToolKind::Config => "minimal",
    _ => "standard",
  }
  .to_string()
}

pub(super) fn summary_font_string(kind: ToolKind, family: ToolFamily) -> String {
  match kind {
    ToolKind::Bash => "mono",
    _ => match family {
      ToolFamily::Shell => "mono",
      _ => "system",
    },
  }
  .to_string()
}
