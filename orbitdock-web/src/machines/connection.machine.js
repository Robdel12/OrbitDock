import { setup, assign } from 'xstate'

const connectionMachine = setup({
  actions: {
    incrementAttempt: assign({
      attempt: ({ context }) => context.attempt + 1,
    }),
    resetAttempt: assign({ attempt: 0 }),
    incrementGeneration: assign({
      generation: ({ context }) => context.generation + 1,
    }),
  },
  guards: {
    canRetry: ({ context }) => context.attempt < context.maxAttempts,
    maxAttemptsReached: ({ context }) => context.attempt >= context.maxAttempts,
  },
  delays: {
    retryDelay: ({ context }) =>
      Math.min(1000 * Math.pow(2, context.attempt), 30000),
  },
}).createMachine({
  id: 'connection',
  initial: 'disconnected',
  context: {
    url: '',
    generation: 0,
    attempt: 0,
    maxAttempts: 10,
    subscribedSessions: new Set(),
  },
  states: {
    disconnected: {
      on: {
        CONNECT: {
          target: 'connecting',
          actions: [
            assign({ url: ({ event }) => event.url }),
            'incrementGeneration',
          ],
        },
      },
    },
    connecting: {
      on: {
        WS_OPEN: { target: 'connected', actions: 'resetAttempt' },
        WS_ERROR: 'reconnecting',
        WS_CLOSE: 'reconnecting',
      },
    },
    connected: {
      on: {
        WS_CLOSE: 'reconnecting',
        WS_ERROR: 'reconnecting',
        DISCONNECT: 'disconnected',
        SUBSCRIBE_SESSION: {
          actions: assign({
            subscribedSessions: ({ context, event }) => {
              const next = new Set(context.subscribedSessions)
              next.add(event.sessionId)
              return next
            },
          }),
        },
        UNSUBSCRIBE_SESSION: {
          actions: assign({
            subscribedSessions: ({ context, event }) => {
              const next = new Set(context.subscribedSessions)
              next.delete(event.sessionId)
              return next
            },
          }),
        },
      },
    },
    reconnecting: {
      after: {
        retryDelay: [
          { guard: 'canRetry', target: 'connecting', actions: 'incrementAttempt' },
          { guard: 'maxAttemptsReached', target: 'failed' },
        ],
      },
    },
    failed: {
      on: {
        RESET: 'disconnected',
      },
    },
  },
})

export { connectionMachine }
