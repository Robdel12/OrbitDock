const createMissionsApi = (http) => ({
  list: () => http.get('/api/missions'),
  get: (id) => http.get(`/api/missions/${id}`),
  create: (body) => http.post('/api/missions', body),
  update: (id, body) => http.put(`/api/missions/${id}`, body),
  remove: (id) => http.del(`/api/missions/${id}`),

  // Issues
  getIssues: (id) => http.get(`/api/missions/${id}/issues`),
  retryIssue: (missionId, issueId) => http.post(`/api/missions/${missionId}/issues/${issueId}/retry`),
  blockIssue: (missionId, issueId, body) => http.post(`/api/missions/${missionId}/issues/${issueId}/blocked`, body),

  // Settings
  getSettings: (id) => http.get(`/api/missions/${id}/settings`),
  updateSettings: (id, body) => http.put(`/api/missions/${id}/settings`, body),

  // Orchestrator
  startOrchestrator: (id) => http.post(`/api/missions/${id}/start-orchestrator`),
  dispatch: (id, body) => http.post(`/api/missions/${id}/dispatch`, body),

  // Scaffold
  scaffold: (id) => http.post(`/api/missions/${id}/scaffold`),
  migrateWorkflow: (id) => http.post(`/api/missions/${id}/migrate-workflow`),
  getDefaultTemplate: (id) => http.get(`/api/missions/${id}/default-template`),
})

export { createMissionsApi }
