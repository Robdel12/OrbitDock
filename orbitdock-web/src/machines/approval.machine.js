import { setup, assign } from 'xstate'

const approvalMachine = setup({
  actions: {
    setRequest: assign({
      request: ({ event }) => event.request,
      approvalVersion: ({ event }) => event.approval_version,
    }),
    setError: assign({
      error: ({ event }) => event.error,
    }),
    updateVersion: assign({
      approvalVersion: ({ event }) => event.approval_version,
    }),
    clearRequest: assign({
      request: null,
      error: null,
    }),
  },
  guards: {
    isNewerVersion: ({ context, event }) =>
      !event.approval_version || event.approval_version > context.approvalVersion,
  },
}).createMachine({
  id: 'approval',
  initial: 'idle',
  context: {
    sessionId: '',
    request: null,
    approvalVersion: 0,
    error: null,
  },
  states: {
    idle: {
      on: {
        APPROVAL_REQUESTED: {
          guard: 'isNewerVersion',
          target: 'pending',
          actions: 'setRequest',
        },
      },
    },
    pending: {
      on: {
        DECIDE: 'submitting',
        ANSWER: 'submitting',
        GRANT_PERMISSION: 'submitting',
        CLEARED: { target: 'idle', actions: 'clearRequest' },
        APPROVAL_REQUESTED: {
          guard: 'isNewerVersion',
          actions: 'setRequest',
        },
      },
    },
    submitting: {
      on: {
        SUBMIT_SUCCESS: {
          target: 'idle',
          actions: ['updateVersion', 'clearRequest'],
        },
        SUBMIT_ERROR: {
          target: 'pending',
          actions: 'setError',
        },
      },
    },
  },
})

export { approvalMachine }
