import { signal } from '@preact/signals'
import { decodeServerMessage } from './codec.js'

const createWsClient = () => {
  let socket = null
  const status = signal('disconnected')
  const lastMessage = signal(null)

  const connect = (url) => {
    if (socket) disconnect()
    status.value = 'connecting'
    socket = new WebSocket(url)

    socket.onopen = () => {
      status.value = 'connected'
    }

    socket.onclose = () => {
      status.value = 'disconnected'
      socket = null
    }

    socket.onerror = () => {
      status.value = 'error'
    }

    socket.onmessage = (event) => {
      const msg = decodeServerMessage(event.data)
      if (msg) lastMessage.value = msg
    }
  }

  const disconnect = () => {
    if (socket) {
      socket.close()
      socket = null
    }
    status.value = 'disconnected'
  }

  const send = (msg) => {
    if (socket && socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify(msg))
    }
  }

  return { status, lastMessage, connect, disconnect, send }
}

export { createWsClient }
