const createReviewsApi = (http) => ({
  update: (commentId, body) => http.patch(`/api/review-comments/${commentId}`, body),
  remove: (commentId) => http.del(`/api/review-comments/${commentId}`),
})

export { createReviewsApi }
