import { ActivityGroupRow } from './activity-group-row.jsx'
import { ApprovalRow } from './approval-row.jsx'
import { AssistantRow } from './assistant-row.jsx'
import { CommandExecutionRow } from './command-execution-row.jsx'
import { HandoffRow } from './handoff-row.jsx'
import { HookRow } from './hook-row.jsx'
import { PlanRow } from './plan-row.jsx'
import { QuestionRow } from './question-row.jsx'
import { SystemRow } from './system-row.jsx'
import { ThinkingRow } from './thinking-row.jsx'
import { ToolRow } from './tool-row.jsx'
import { UserRow } from './user-row.jsx'
import { WorkerRow } from './worker-row.jsx'

const ROW_COMPONENTS = {
  user: UserRow,
  assistant: AssistantRow,
  thinking: ThinkingRow,
  system: SystemRow,
  tool: ToolRow,
  command_execution: CommandExecutionRow,
  activity_group: ActivityGroupRow,
  question: QuestionRow,
  approval: ApprovalRow,
  worker: WorkerRow,
  plan: PlanRow,
  hook: HookRow,
  handoff: HandoffRow,
}

const RowDispatcher = ({ entry }) => {
  const row = entry.row
  if (!row) return null
  const Component = ROW_COMPONENTS[row.row_type]
  return Component ? <Component entry={entry} /> : null
}

export { RowDispatcher }
