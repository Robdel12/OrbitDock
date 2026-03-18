import { useState, useEffect } from 'preact/hooks'
import { createHttpClient } from '../../api/http.js'
import { Card } from '../ui/card.jsx'
import { Badge } from '../ui/badge.jsx'
import { Button } from '../ui/button.jsx'
import { Spinner } from '../ui/spinner.jsx'
import styles from './skills-panel.module.css'

const http = createHttpClient('')

// ---------------------------------------------------------------------------
// SkillRow — a single installed skill with an enable/disable toggle
// ---------------------------------------------------------------------------

const SkillRow = ({ skill, sessionId, onToggle }) => {
  const [toggling, setToggling] = useState(false)

  const handleToggle = async () => {
    if (toggling) return
    setToggling(true)
    try {
      await onToggle(skill)
    } finally {
      setToggling(false)
    }
  }

  return (
    <div class={styles.skillRow}>
      <div class={styles.skillInfo}>
        <span class={styles.skillName}>{skill.name}</span>
        {skill.description && (
          <span class={styles.skillDesc}>{skill.description}</span>
        )}
      </div>
      <div class={styles.skillActions}>
        <Badge variant="status" color={skill.enabled ? 'feedback-positive' : 'status-ended'}>
          {skill.enabled ? 'enabled' : 'disabled'}
        </Badge>
        <button
          class={`${styles.toggleSwitch} ${skill.enabled ? styles.toggleOn : ''}`}
          onClick={handleToggle}
          disabled={toggling}
          aria-label={skill.enabled ? `Disable ${skill.name}` : `Enable ${skill.name}`}
          aria-checked={skill.enabled}
          role="switch"
        >
          {toggling && <Spinner size="sm" />}
        </button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// RemoteSkillRow — an installable skill from the remote catalog
// ---------------------------------------------------------------------------

const RemoteSkillRow = ({ skill, sessionId, onDownload, downloading }) => (
  <div class={styles.skillRow}>
    <div class={styles.skillInfo}>
      <span class={styles.skillName}>{skill.name}</span>
      {skill.description && (
        <span class={styles.skillDesc}>{skill.description}</span>
      )}
      {skill.version && (
        <span class={styles.skillMeta}>v{skill.version}</span>
      )}
    </div>
    <div class={styles.skillActions}>
      <Button
        size="sm"
        variant="ghost"
        loading={downloading}
        onClick={() => onDownload(skill)}
      >
        Install
      </Button>
    </div>
  </div>
)

// ---------------------------------------------------------------------------
// SkillsPanel
// ---------------------------------------------------------------------------

const SkillsPanel = ({ sessionId, liveSkills }) => {
  const [skills, setSkills] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const [browseOpen, setBrowseOpen] = useState(false)
  const [remoteSkills, setRemoteSkills] = useState([])
  const [remoteLoading, setRemoteLoading] = useState(false)
  const [remoteError, setRemoteError] = useState(null)
  const [downloadingId, setDownloadingId] = useState(null)

  // Initial fetch
  useEffect(() => {
    if (!sessionId) return
    setLoading(true)
    setError(null)
    http.get(`/api/sessions/${sessionId}/skills`)
      .then((data) => {
        setSkills(data?.skills || data || [])
      })
      .catch((err) => {
        setError(err.message)
      })
      .finally(() => {
        setLoading(false)
      })
  }, [sessionId])

  // Apply live WS updates (skills_list event)
  useEffect(() => {
    if (!liveSkills) return
    setSkills(liveSkills)
  }, [liveSkills])

  const handleToggle = async (skill) => {
    // Optimistic update
    setSkills((prev) =>
      prev.map((s) => s.id === skill.id ? { ...s, enabled: !s.enabled } : s)
    )
    try {
      await http.post(`/api/sessions/${sessionId}/skills/toggle`, {
        skill_id: skill.id,
        enabled: !skill.enabled,
      })
    } catch (err) {
      // Revert on failure
      setSkills((prev) =>
        prev.map((s) => s.id === skill.id ? { ...s, enabled: skill.enabled } : s)
      )
      console.warn('[skills] toggle failed:', err.message)
    }
  }

  const handleBrowse = async () => {
    setBrowseOpen(true)
    if (remoteSkills.length > 0) return
    setRemoteLoading(true)
    setRemoteError(null)
    try {
      const data = await http.get(`/api/sessions/${sessionId}/skills/remote`)
      setRemoteSkills(data?.skills || data || [])
    } catch (err) {
      setRemoteError(err.message)
    } finally {
      setRemoteLoading(false)
    }
  }

  const handleDownload = async (skill) => {
    if (downloadingId) return
    setDownloadingId(skill.id)
    try {
      await http.post(`/api/sessions/${sessionId}/skills/download`, { skill_id: skill.id })
      // Remove from remote list once installed; WS skills_list will refresh local list
      setRemoteSkills((prev) => prev.filter((s) => s.id !== skill.id))
    } catch (err) {
      console.warn('[skills] download failed:', err.message)
    } finally {
      setDownloadingId(null)
    }
  }

  return (
    <div class={styles.panel}>
      <div class={styles.header}>
        <span class={styles.headerTitle}>Skills</span>
        <Button size="sm" variant="ghost" onClick={handleBrowse}>
          Browse Remote
        </Button>
      </div>

      {loading && (
        <div class={styles.center}>
          <Spinner size="md" />
        </div>
      )}

      {!loading && error && (
        <div class={styles.errorMsg}>{error}</div>
      )}

      {!loading && !error && skills.length === 0 && (
        <div class={styles.emptyMsg}>No skills installed for this session.</div>
      )}

      {!loading && skills.length > 0 && (
        <div class={styles.list}>
          {skills.map((skill) => (
            <SkillRow
              key={skill.id || skill.name}
              skill={skill}
              sessionId={sessionId}
              onToggle={handleToggle}
            />
          ))}
        </div>
      )}

      {browseOpen && (
        <div class={styles.browseSection}>
          <div class={styles.browseHeader}>
            <span class={styles.browseSectionTitle}>Remote Skills</span>
            <button
              class={styles.closeBtn}
              onClick={() => setBrowseOpen(false)}
              aria-label="Close remote skills"
            >
              ✕
            </button>
          </div>

          {remoteLoading && (
            <div class={styles.center}>
              <Spinner size="md" />
            </div>
          )}

          {!remoteLoading && remoteError && (
            <div class={styles.errorMsg}>{remoteError}</div>
          )}

          {!remoteLoading && !remoteError && remoteSkills.length === 0 && (
            <div class={styles.emptyMsg}>No remote skills available.</div>
          )}

          {!remoteLoading && remoteSkills.length > 0 && (
            <div class={styles.list}>
              {remoteSkills.map((skill) => (
                <RemoteSkillRow
                  key={skill.id || skill.name}
                  skill={skill}
                  sessionId={sessionId}
                  onDownload={handleDownload}
                  downloading={downloadingId === skill.id}
                />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  )
}

export { SkillsPanel }
