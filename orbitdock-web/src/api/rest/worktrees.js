const createWorktreesApi = (http) => ({
  list: (params) => http.get('/api/worktrees', params),
  create: (body) => http.post('/api/worktrees', body),
  discover: (body) => http.post('/api/worktrees/discover', body),
  remove: (id, params) => {
    const query = params ? `?${new URLSearchParams(params)}` : ''
    return http.del(`/api/worktrees/${id}${query}`)
  },
})

export { createWorktreesApi }
