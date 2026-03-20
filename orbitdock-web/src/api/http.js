/**
 * Create an HTTP client.
 * `tokenAccessor` can be a string (static) or a function that returns the current token.
 * When a function is provided, the token is read fresh on every request.
 * `on401` optional callback invoked when a 401 response is received.
 */
const createHttpClient = (baseUrl, tokenAccessor, { on401 } = {}) => {
  const getToken = typeof tokenAccessor === 'function' ? tokenAccessor : () => tokenAccessor

  const request = async (method, path, body) => {
    const token = getToken()
    const headers = { 'Content-Type': 'application/json' }
    if (token) headers['Authorization'] = `Bearer ${token}`
    const res = await fetch(`${baseUrl}${path}`, {
      method,
      headers,
      body: body ? JSON.stringify(body) : undefined,
    })
    if (!res.ok) {
      if (res.status === 401 && on401) on401()
      const err = await res.json().catch(() => ({}))
      throw Object.assign(new Error(err.error || res.statusText), {
        status: res.status,
        code: err.code,
      })
    }
    const text = await res.text()
    return text ? JSON.parse(text) : null
  }
  return {
    get: (path, params) =>
      request('GET', params ? `${path}?${new URLSearchParams(params)}` : path),
    post: (path, body) => request('POST', path, body),
    put: (path, body) => request('PUT', path, body),
    patch: (path, body) => request('PATCH', path, body),
    del: (path, body) => request('DELETE', path, body),
  }
}

export { createHttpClient }
