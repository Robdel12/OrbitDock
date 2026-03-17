const createSessionsApi = (http) => ({
  // Reads
  list: () => http.get('/api/sessions'),
  get: (id) => http.get(`/api/sessions/${id}`),
  getConversation: (id, params) => http.get(`/api/sessions/${id}/conversation`, params),
  getMessages: (id, params) => http.get(`/api/sessions/${id}/messages`, params),
  getRowContent: (sessionId, rowId) => http.get(`/api/sessions/${sessionId}/rows/${rowId}/content`),
  getStats: (id) => http.get(`/api/sessions/${id}/stats`),

  // Lifecycle
  create: (body) => http.post('/api/sessions', body),
  resume: (id) => http.post(`/api/sessions/${id}/resume`),
  end: (id) => http.post(`/api/sessions/${id}/end`),
  fork: (id, body) => http.post(`/api/sessions/${id}/fork`, body),
  rename: (id, body) => http.patch(`/api/sessions/${id}/name`, body),

  // Actions
  sendMessage: (id, body) => http.post(`/api/sessions/${id}/messages`, body),
  steer: (id, body) => http.post(`/api/sessions/${id}/steer`, body),
  interrupt: (id) => http.post(`/api/sessions/${id}/interrupt`),
  compact: (id) => http.post(`/api/sessions/${id}/compact`),
  undo: (id) => http.post(`/api/sessions/${id}/undo`),
  rollback: (id, body) => http.post(`/api/sessions/${id}/rollback`, body),
  markRead: (id) => http.post(`/api/sessions/${id}/mark-read`),

  // Search
  search: (id, params) => http.get(`/api/sessions/${id}/search`, params),

  // Takeover
  takeover: (id, body) => http.post(`/api/sessions/${id}/takeover`, body),

  // Fork variants
  forkToWorktree: (id, body) => http.post(`/api/sessions/${id}/fork-to-worktree`, body),
  forkToExistingWorktree: (id, body) => http.post(`/api/sessions/${id}/fork-to-existing-worktree`, body),

  // Task management
  stopTask: (id, body) => http.post(`/api/sessions/${id}/stop-task`, body),
  rewindFiles: (id, body) => http.post(`/api/sessions/${id}/rewind-files`, body),

  // Subagents
  getSubagentTools: (id, subagentId) => http.get(`/api/sessions/${id}/subagents/${subagentId}/tools`),
  getSubagentMessages: (id, subagentId) => http.get(`/api/sessions/${id}/subagents/${subagentId}/messages`),

  // Instructions
  getInstructions: (id) => http.get(`/api/sessions/${id}/instructions`),

  // Config
  updateConfig: (id, body) => http.patch(`/api/sessions/${id}/config`, body),

  // Permissions
  getPermissions: (id) => http.get(`/api/sessions/${id}/permissions`),
  addPermissionRule: (id, body) => http.post(`/api/sessions/${id}/permissions/rules`, body),
  deletePermissionRule: (id, body) => http.del(`/api/sessions/${id}/permissions/rules`, body),

  // Skills
  getSkills: (id, params) => http.get(`/api/sessions/${id}/skills`, params),
  getRemoteSkills: (id) => http.get(`/api/sessions/${id}/skills/remote`),
  downloadSkill: (id, body) => http.post(`/api/sessions/${id}/skills/download`, body),

  // MCP
  getMcpTools: (id) => http.get(`/api/sessions/${id}/mcp/tools`),
  refreshMcp: (id, body) => http.post(`/api/sessions/${id}/mcp/refresh`, body),
  toggleMcp: (id, body) => http.post(`/api/sessions/${id}/mcp/toggle`, body),
  authenticateMcp: (id, body) => http.post(`/api/sessions/${id}/mcp/authenticate`, body),
  clearMcpAuth: (id, body) => http.post(`/api/sessions/${id}/mcp/clear-auth`, body),
  configureMcpServers: (id, body) => http.post(`/api/sessions/${id}/mcp/servers`, body),

  // Flags
  setFlags: (id, body) => http.post(`/api/sessions/${id}/flags`, body),

  // Attachments
  getImage: (id, attachmentId) => http.get(`/api/sessions/${id}/attachments/images/${attachmentId}`),

  // Shell
  shellExec: (id, body) => http.post(`/api/sessions/${id}/shell/exec`, body),
  shellCancel: (id, body) => http.post(`/api/sessions/${id}/shell/cancel`, body),

  // Review comments
  getReviewComments: (id, params) => http.get(`/api/sessions/${id}/review-comments`, params),
  createReviewComment: (id, body) => http.post(`/api/sessions/${id}/review-comments`, body),
})

export { createSessionsApi }
