const createCodexApi = (http) => ({
  getAccount: (params) => http.get('/api/codex/account', params),
  startLogin: () => http.post('/api/codex/login/start'),
  cancelLogin: (loginId) => http.post('/api/codex/login/cancel', { login_id: loginId }),
  logout: () => http.post('/api/codex/logout'),
})

export { createCodexApi }
