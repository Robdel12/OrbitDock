const KNOWN_SERVER_TYPES = new Set([
  'sessions_list',
  'conversation_bootstrap',
  'session_delta',
  'conversation_rows_changed',
  'approval_requested',
  'tokens_updated',
  'session_created',
  'session_list_item_updated',
  'session_list_item_removed',
  'session_ended',
  'session_forked',
  'approvals_list',
  'approval_deleted',
  'models_list',
  'codex_account_status',
  'skills_list',
  'mcp_tools_list',
  'claude_models_list',
  'claude_capabilities',
  'context_compacted',
  'undo_started',
  'undo_completed',
  'thread_rolled_back',
  'turn_diff_snapshot',
  'review_comment_created',
  'review_comment_updated',
  'review_comment_deleted',
  'review_comments_list',
  'shell_started',
  'shell_output',
  'directory_listing',
  'recent_projects_list',
  'codex_usage_result',
  'claude_usage_result',
  'open_ai_key_status',
  'server_info',
  'approval_decision_result',
  'worktrees_list',
  'worktree_created',
  'worktree_removed',
  'worktree_status_changed',
  'worktree_error',
  'rate_limit_event',
  'prompt_suggestion',
  'files_persisted',
  'permission_rules',
  'missions_list',
  'mission_delta',
  'codex_account_updated',
  'codex_login_chatgpt_started',
  'codex_login_chatgpt_completed',
  'codex_login_chatgpt_canceled',
  'mcp_startup_update',
  'mcp_startup_complete',
  'skills_update_available',
  'subagent_tools_list',
  'error',
])

const KNOWN_ROW_TYPES = new Set([
  'user',
  'assistant',
  'thinking',
  'system',
  'tool',
  'activity_group',
  'question',
  'approval',
  'worker',
  'plan',
  'hook',
  'handoff',
])

const encodeClientMessage = (msg) => JSON.stringify(msg)

const decodeServerMessage = (raw) => {
  try {
    const msg = typeof raw === 'string' ? JSON.parse(raw) : raw
    if (!msg || !msg.type) {
      console.warn('[codec] message missing type field:', msg)
      return null
    }
    if (!KNOWN_SERVER_TYPES.has(msg.type)) {
      console.warn('[codec] unknown server message type:', msg.type)
      return null
    }
    return msg
  } catch (err) {
    console.warn('[codec] failed to parse server message:', err.message)
    return null
  }
}

const isKnownRowType = (rowType) => KNOWN_ROW_TYPES.has(rowType)

export { encodeClientMessage, decodeServerMessage, isKnownRowType, KNOWN_SERVER_TYPES, KNOWN_ROW_TYPES }
