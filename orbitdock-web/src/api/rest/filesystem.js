const createFilesystemApi = (http) => ({
  browse: (path) => http.get('/api/fs/browse', path ? { path } : undefined),
  recentProjects: () => http.get('/api/fs/recent-projects'),
  gitInit: (path) => http.post('/api/git/init', { path }),
})

export { createFilesystemApi }
