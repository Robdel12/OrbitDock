import { useState } from 'preact/hooks'
import { TabBar } from '../ui/tab-bar.jsx'
import { SkillsPanel } from './skills-panel.jsx'
import { McpPanel } from './mcp-panel.jsx'
import styles from './capabilities-panel.module.css'

const TABS = [
  { id: 'skills', label: 'Plugins' },
  { id: 'mcp', label: 'MCP' },
]

// ---------------------------------------------------------------------------
// CapabilitiesPanel
//
// Props:
//   open        — boolean, whether the panel is visible
//   onClose     — callback to close
//   sessionId   — current session ID
//   liveSkills  — latest skills_list WS payload (or null)
//   liveMcpTools — latest mcp_tools_list WS payload (or null)
// ---------------------------------------------------------------------------

const CapabilitiesPanel = ({ open, onClose, sessionId, liveSkills, liveMcpTools }) => {
  const [activeTab, setActiveTab] = useState('skills')

  // Close on backdrop click (mobile overlay only)
  const handleBackdropClick = (e) => {
    if (e.target === e.currentTarget) onClose()
  }

  return (
    <>
      {/* Backdrop — only rendered on mobile (hidden on desktop via CSS) */}
      {open && (
        <div
          class={styles.backdrop}
          onClick={handleBackdropClick}
          aria-hidden="true"
        />
      )}

      <div
        class={`${styles.panel} ${open ? styles.panelOpen : ''}`}
        role="dialog"
        aria-label="Capabilities"
        aria-hidden={!open}
      >
        <div class={styles.panelInner}>
          {/* Panel header */}
          <div class={styles.panelHeader}>
            <span class={styles.panelTitle}>Capabilities</span>
            <button
              class={styles.closeBtn}
              onClick={onClose}
              aria-label="Close capabilities panel"
            >
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"><path d="M2 2l8 8M10 2l-8 8"/></svg>
            </button>
          </div>

          {/* Tab bar */}
          <TabBar
            tabs={TABS}
            activeTab={activeTab}
            onTabChange={setActiveTab}
          />

          {/* Tab content */}
          <div class={styles.content}>
            {activeTab === 'skills' && (
              <SkillsPanel sessionId={sessionId} liveSkills={liveSkills} />
            )}
            {activeTab === 'mcp' && (
              <McpPanel sessionId={sessionId} liveMcpTools={liveMcpTools} />
            )}
          </div>
        </div>
      </div>
    </>
  )
}

export { CapabilitiesPanel }
