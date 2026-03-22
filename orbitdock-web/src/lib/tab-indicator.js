import { sessions } from '../stores/sessions.js'

const BASE_TITLE = 'OrbitDock'

// Generates a 16x16 favicon data URL with an optional dot overlay.
// color — CSS hex string for the dot (e.g. '#F26673')
const buildFaviconDataUrl = (dotColor) => {
  const canvas = document.createElement('canvas')
  canvas.width = 32
  canvas.height = 32
  const ctx = canvas.getContext('2d')

  // Base icon: simple orbital circle (placeholder design)
  ctx.strokeStyle = '#54AEE5'
  ctx.lineWidth = 3
  ctx.beginPath()
  ctx.arc(16, 16, 11, 0, Math.PI * 2)
  ctx.stroke()

  // Inner dot
  ctx.fillStyle = '#54AEE5'
  ctx.beginPath()
  ctx.arc(16, 16, 4, 0, Math.PI * 2)
  ctx.fill()

  if (dotColor) {
    // Notification dot in the top-right corner
    ctx.fillStyle = dotColor
    ctx.beginPath()
    ctx.arc(26, 6, 6, 0, Math.PI * 2)
    ctx.fill()
  }

  return canvas.toDataURL('image/png')
}

let faviconEl = null

const getFaviconEl = () => {
  if (faviconEl) return faviconEl
  faviconEl = document.querySelector("link[rel~='icon']")
  if (!faviconEl) {
    faviconEl = document.createElement('link')
    faviconEl.rel = 'icon'
    faviconEl.type = 'image/png'
    document.head.appendChild(faviconEl)
  }
  return faviconEl
}

const setFavicon = (dotColor) => {
  const el = getFaviconEl()
  el.href = buildFaviconDataUrl(dotColor)
}

// Reads current session states and updates the document title + favicon.
const updateTabIndicator = () => {
  const all = [...sessions.value.values()]

  const needsApproval = all.some((s) => s.work_status === 'waiting_for_approval')
  const workingCount = all.filter((s) => s.work_status === 'working').length

  if (needsApproval) {
    document.title = `⚠ ${BASE_TITLE}`
    setFavicon('#F28C6B')
  } else if (workingCount > 0) {
    document.title = workingCount > 1 ? `(${workingCount}) ${BASE_TITLE}` : BASE_TITLE
    setFavicon('#54AEE5')
  } else {
    document.title = BASE_TITLE
    setFavicon(null)
  }
}

// Sets up a signal subscription and returns the unsubscribe function.
const initTabIndicator = () => {
  updateTabIndicator()
  return sessions.subscribe(() => updateTabIndicator())
}

export { initTabIndicator, updateTabIndicator }
