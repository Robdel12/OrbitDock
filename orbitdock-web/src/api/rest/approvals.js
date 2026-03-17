const createApprovalsApi = (http) => ({
  approve: (sessionId, body) =>
    http.post(`/api/sessions/${sessionId}/approve`, body),
  answer: (sessionId, body) =>
    http.post(`/api/sessions/${sessionId}/answer`, body),
  respondToPermission: (sessionId, body) =>
    http.post(`/api/sessions/${sessionId}/permissions/respond`, body),
})

export { createApprovalsApi }
