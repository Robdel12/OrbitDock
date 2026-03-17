const createServerApi = (http) => ({
  // Health
  health: () => http.get('/health'),

  // Models
  claudeModels: () => http.get('/api/models/claude'),
  codexModels: () => http.get('/api/models/codex'),

  // Usage
  claudeUsage: () => http.get('/api/usage/claude'),
  codexUsage: () => http.get('/api/usage/codex'),

  // API Keys
  getOpenAiKey: () => http.get('/api/server/openai-key'),
  setOpenAiKey: (key) => http.post('/api/server/openai-key', { key }),
  getLinearKey: () => http.get('/api/server/linear-key'),
  setLinearKey: (key) => http.post('/api/server/linear-key', { key }),
  deleteLinearKey: () => http.del('/api/server/linear-key'),
  getTrackerKeys: () => http.get('/api/server/tracker-keys'),

  // Server role
  setRole: (isPrimary) => http.put('/api/server/role', { is_primary: isPrimary }),

  // Client primary claim
  claimPrimary: (clientId, deviceName, isPrimary) =>
    http.post('/api/client/primary-claim', { client_id: clientId, device_name: deviceName, is_primary: isPrimary }),

  // Mission defaults
  getMissionDefaults: () => http.get('/api/server/mission-defaults'),
  setMissionDefaults: (body) => http.put('/api/server/mission-defaults', body),
})

export { createServerApi }
