import assert from 'node:assert/strict'
import { beforeEach, describe, it } from 'node:test'
import {
  applyResumeSummary,
  handleSessionDelta,
  handleSessionEnded,
  handleSessionsList,
  selected,
  selectedId,
  sessions,
} from '../../src/stores/sessions.js'

const endedSession = () => ({
  id: 'sess-1',
  provider: 'claude',
  project_path: '/tmp/project',
  status: 'ended',
  work_status: 'ended',
  git_branch: 'main',
})

describe('sessions store', () => {
  beforeEach(() => {
    sessions.value = new Map()
    selectedId.value = null
  })

  describe('handleSessionsList', () => {
    it('replaces all sessions', () => {
      handleSessionsList([
        { id: 's1', status: 'active', work_status: 'working' },
        { id: 's2', status: 'ended', work_status: 'ended' },
      ])
      assert.strictEqual(sessions.value.size, 2)
      assert.strictEqual(sessions.value.get('s1').status, 'active')
    })
  })

  describe('handleSessionDelta', () => {
    it('merges partial updates into existing session', () => {
      handleSessionsList([{ id: 's1', status: 'active', work_status: 'working' }])
      handleSessionDelta('s1', { work_status: 'reply' })
      assert.strictEqual(sessions.value.get('s1').work_status, 'reply')
    })

    it('applies permission_mode from delta', () => {
      handleSessionsList([{ id: 's1', status: 'active', work_status: 'working', permission_mode: 'default' }])
      handleSessionDelta('s1', { permission_mode: 'plan' })
      assert.strictEqual(sessions.value.get('s1').permission_mode, 'plan')
    })

    it('clears permission_mode when delta sets null', () => {
      handleSessionsList([{ id: 's1', status: 'active', work_status: 'working', permission_mode: 'plan' }])
      handleSessionDelta('s1', { permission_mode: null })
      assert.strictEqual(sessions.value.get('s1').permission_mode, null)
    })

    it('preserves permission_mode when delta does not include it', () => {
      handleSessionsList([{ id: 's1', status: 'active', work_status: 'working', permission_mode: 'acceptEdits' }])
      handleSessionDelta('s1', { work_status: 'reply' })
      assert.strictEqual(sessions.value.get('s1').permission_mode, 'acceptEdits')
    })
  })

  describe('handleSessionEnded', () => {
    it('sets status and work_status to ended', () => {
      handleSessionsList([{ id: 's1', status: 'active', work_status: 'working' }])
      handleSessionEnded('s1')
      assert.strictEqual(sessions.value.get('s1').status, 'ended')
      assert.strictEqual(sessions.value.get('s1').work_status, 'ended')
    })
  })

  describe('applyResumeSummary', () => {
    it('updates ended session to active from resume response', () => {
      handleSessionsList([endedSession()])
      selectedId.value = 'sess-1'

      applyResumeSummary('sess-1', {
        id: 'sess-1',
        status: 'active',
        work_status: 'working',
        model: 'claude-sonnet-4',
      })

      const session = sessions.value.get('sess-1')
      assert.strictEqual(session.status, 'active')
      assert.strictEqual(session.work_status, 'working')
      assert.strictEqual(session.model, 'claude-sonnet-4')
    })

    it('makes selected signal reflect the resumed state', () => {
      handleSessionsList([endedSession()])
      selectedId.value = 'sess-1'

      assert.strictEqual(selected.value.status, 'ended')

      applyResumeSummary('sess-1', {
        id: 'sess-1',
        status: 'active',
        work_status: 'reply',
      })

      assert.strictEqual(selected.value.status, 'active')
      assert.strictEqual(selected.value.work_status, 'reply')
    })

    it('preserves existing fields not in the summary', () => {
      handleSessionsList([{ ...endedSession(), custom_name: 'my session' }])

      applyResumeSummary('sess-1', {
        id: 'sess-1',
        status: 'active',
        work_status: 'working',
      })

      assert.strictEqual(sessions.value.get('sess-1').custom_name, 'my session')
    })

    it('no-ops when session does not exist', () => {
      applyResumeSummary('nonexistent', { id: 'nonexistent', status: 'active' })
      assert.strictEqual(sessions.value.size, 0)
    })

    it('normalizes git_branch to branch', () => {
      handleSessionsList([endedSession()])

      applyResumeSummary('sess-1', {
        id: 'sess-1',
        status: 'active',
        work_status: 'working',
        git_branch: 'feature/resume-fix',
      })

      const session = sessions.value.get('sess-1')
      assert.strictEqual(session.branch, 'feature/resume-fix')
      assert.strictEqual(session.git_branch, 'feature/resume-fix')
    })

    it('applies permission_mode from resume summary', () => {
      handleSessionsList([endedSession()])

      applyResumeSummary('sess-1', {
        id: 'sess-1',
        status: 'active',
        work_status: 'working',
        permission_mode: 'acceptEdits',
      })

      assert.strictEqual(sessions.value.get('sess-1').permission_mode, 'acceptEdits')
    })
  })
})
