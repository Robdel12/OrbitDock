import { useEffect, useState } from 'preact/hooks'
import { http } from '../../stores/connection.js'
import { Badge } from '../ui/badge.jsx'
import { Button } from '../ui/button.jsx'
import { Spinner } from '../ui/spinner.jsx'
import styles from './skills-panel.module.css'

const toArray = (value) => (Array.isArray(value) ? value : [])

const textOr = (value, fallback = '') =>
  typeof value === 'string' && value.trim() ? value.trim() : fallback

const normalizeSkills = (data) => {
  if (Array.isArray(data)) return data
  if (Array.isArray(data?.skills)) return data.skills
  return []
}

const normalizePluginCatalog = (data) => {
  const marketplaces = toArray(data?.marketplaces)
    .map((marketplace, index) => ({
      ...marketplace,
      plugins: toArray(marketplace?.plugins),
      __key: textOr(marketplace?.path) || textOr(marketplace?.name) || `marketplace-${index}`,
    }))

  if (marketplaces.length > 0) {
    return {
      marketplaces,
      remoteSyncError: textOr(data?.remote_sync_error || data?.remoteSyncError),
    }
  }

  const plugins = toArray(data?.plugins)
  if (plugins.length > 0) {
    return {
      marketplaces: [
        {
          name: 'Plugins',
          path: '',
          interface: null,
          plugins,
          __key: 'plugins',
        },
      ],
      remoteSyncError: textOr(data?.remote_sync_error || data?.remoteSyncError),
    }
  }

  return {
    marketplaces: [],
    remoteSyncError: textOr(data?.remote_sync_error || data?.remoteSyncError),
  }
}

const pluginDisplayName = (plugin) =>
  textOr(plugin?.interface?.display_name) ||
  textOr(plugin?.name) ||
  textOr(plugin?.id) ||
  'Untitled plugin'

const pluginDescription = (plugin) =>
  textOr(plugin?.interface?.short_description) ||
  textOr(plugin?.interface?.long_description) ||
  textOr(plugin?.description)

const marketplaceDisplayName = (marketplace) =>
  textOr(marketplace?.interface?.display_name) ||
  textOr(marketplace?.name) ||
  textOr(marketplace?.path) ||
  'Marketplace'

const marketplaceDescription = (marketplace) =>
  textOr(marketplace?.interface?.short_description) ||
  textOr(marketplace?.interface?.long_description) ||
  textOr(marketplace?.interface?.developer_name)

const matchesQuery = (text, query) => text.toLowerCase().includes(query)

const skillMatches = (skill, query) => {
  if (!query) return true
  const haystack = [
    skill?.name,
    skill?.description,
    skill?.id,
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase()
  return haystack.includes(query)
}

const pluginMatches = (plugin, marketplace, query) => {
  if (!query) return true
  const haystack = [
    pluginDisplayName(plugin),
    pluginDescription(plugin),
    plugin?.name,
    plugin?.id,
    plugin?.source,
    plugin?.install_policy,
    plugin?.auth_policy,
    marketplaceDisplayName(marketplace),
    marketplace?.path,
    marketplaceDescription(marketplace),
    plugin?.interface?.developer_name,
    plugin?.interface?.category,
  ]
    .filter(Boolean)
    .join(' ')
    .toLowerCase()
  return matchesQuery(haystack, query)
}

const getPluginKey = (plugin, marketplace, index) =>
  textOr(plugin?.id) ||
  `${textOr(marketplace?.__key, 'marketplace')}:${textOr(plugin?.name, `plugin-${index}`)}`

const getSkillKey = (skill, index) => textOr(skill?.id) || textOr(skill?.name, `skill-${index}`)

const StatCard = ({ value, label }) => (
  <div class={styles.statCard}>
    <span class={styles.statValue}>{value}</span>
    <span class={styles.statLabel}>{label}</span>
  </div>
)

const SkillRow = ({ skill, onToggle }) => {
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

const PluginCard = ({ plugin, marketplace, onAction, busy }) => {
  const accent = plugin?.interface?.brand_color || marketplace?.interface?.brand_color
  const capabilities = toArray(plugin?.interface?.capabilities)
  const isInstalled = Boolean(plugin?.installed)
  const isEnabled = Boolean(plugin?.enabled)

  return (
    <article class={styles.pluginCard} style={accent ? { '--plugin-accent': accent } : undefined}>
      <div class={styles.pluginTop}>
        <div class={styles.pluginTitleRow}>
          <span class={styles.pluginAccent} aria-hidden="true" />
          <div class={styles.pluginTitleGroup}>
            <h3 class={styles.pluginTitle}>{pluginDisplayName(plugin)}</h3>
            {pluginDescription(plugin) && (
              <p class={styles.pluginSubtitle}>{pluginDescription(plugin)}</p>
            )}
          </div>
        </div>

        <div class={styles.pluginBadges}>
          <Badge variant="status" color={isInstalled ? 'feedback-positive' : 'status-ended'}>
            {isInstalled ? 'installed' : 'available'}
          </Badge>
          {isInstalled && (
            <Badge variant="status" color={isEnabled ? 'feedback-positive' : 'feedback-warning'}>
              {isEnabled ? 'enabled' : 'disabled'}
            </Badge>
          )}
          {plugin?.source && <Badge variant="meta">{plugin.source}</Badge>}
          {plugin?.install_policy && <Badge variant="meta">{plugin.install_policy}</Badge>}
          {plugin?.auth_policy && <Badge variant="meta">{plugin.auth_policy}</Badge>}
          {capabilities.length > 0 && (
            <Badge variant="meta">{capabilities.length} capabilities</Badge>
          )}
        </div>
      </div>

      <div class={styles.pluginFooter}>
        <div class={styles.pluginMeta}>
          {marketplaceDisplayName(marketplace)}
          {plugin?.interface?.developer_name && (
            <span class={styles.pluginDeveloper}>{plugin.interface.developer_name}</span>
          )}
        </div>

        <Button
          size="sm"
          variant={isInstalled ? 'danger' : 'primary'}
          loading={busy}
          disabled={busy}
          onClick={() => onAction(plugin, marketplace)}
        >
          {isInstalled ? 'Uninstall' : 'Install'}
        </Button>
      </div>
    </article>
  )
}

const SkillsPanel = ({ sessionId, liveSkills }) => {
  const [skills, setSkills] = useState([])
  const [skillsLoading, setSkillsLoading] = useState(true)
  const [skillsError, setSkillsError] = useState(null)

  const [marketplaces, setMarketplaces] = useState([])
  const [catalogLoading, setCatalogLoading] = useState(true)
  const [catalogError, setCatalogError] = useState(null)
  const [remoteSyncError, setRemoteSyncError] = useState(null)

  const [search, setSearch] = useState('')
  const [actionError, setActionError] = useState(null)
  const [busyPluginKey, setBusyPluginKey] = useState(null)

  useEffect(() => {
    if (!sessionId) return undefined

    let cancelled = false

    setSkills([])
    setSkillsLoading(true)
    setSkillsError(null)
    setMarketplaces([])
    setCatalogLoading(true)
    setCatalogError(null)
    setRemoteSyncError(null)
    setSearch('')
    setActionError(null)
    setBusyPluginKey(null)

    const loadSkills = async () => {
      try {
        const data = await http.get(`/api/sessions/${sessionId}/skills`)
        if (!cancelled) {
          setSkills(normalizeSkills(data))
        }
      } catch (err) {
        if (!cancelled) {
          setSkillsError(err.message)
        }
      } finally {
        if (!cancelled) {
          setSkillsLoading(false)
        }
      }
    }

    const loadCatalog = async () => {
      try {
        const data = await http.get(`/api/sessions/${sessionId}/plugins`, { force_remote_sync: true })
        if (!cancelled) {
          const normalized = normalizePluginCatalog(data)
          setMarketplaces(normalized.marketplaces)
          setRemoteSyncError(normalized.remoteSyncError)
        }
      } catch (err) {
        if (!cancelled) {
          setCatalogError(err.message)
        }
      } finally {
        if (!cancelled) {
          setCatalogLoading(false)
        }
      }
    }

    void loadSkills()
    void loadCatalog()

    return () => {
      cancelled = true
    }
  }, [sessionId])

  useEffect(() => {
    if (!liveSkills) return
    setSkillsError(null)
    setSkills(normalizeSkills(liveSkills))
  }, [liveSkills])

  const refreshSkills = async () => {
    try {
      const data = await http.get(`/api/sessions/${sessionId}/skills`)
      setSkillsError(null)
      setSkills(normalizeSkills(data))
    } catch (err) {
      setSkillsError(err.message)
      throw err
    }
  }

  const refreshCatalog = async () => {
    try {
      const data = await http.get(`/api/sessions/${sessionId}/plugins`, { force_remote_sync: true })
      const normalized = normalizePluginCatalog(data)
      setCatalogError(null)
      setMarketplaces(normalized.marketplaces)
      setRemoteSyncError(normalized.remoteSyncError)
    } catch (err) {
      setCatalogError(err.message)
      throw err
    }
  }

  const handleToggle = async (skill) => {
    setSkills((prev) =>
      prev.map((current) => (
        current.id === skill.id
          ? { ...current, enabled: !current.enabled }
          : current
      ))
    )

    try {
      await http.post(`/api/sessions/${sessionId}/skills/toggle`, {
        skill_id: skill.id,
        enabled: !skill.enabled,
      })
    } catch (err) {
      setSkills((prev) =>
        prev.map((current) => (
          current.id === skill.id
            ? { ...current, enabled: skill.enabled }
            : current
        ))
      )
      setSkillsError(err.message)
      console.warn('[skills] toggle failed:', err.message)
    }
  }

  const handlePluginAction = async (plugin, marketplace) => {
    if (!plugin || busyPluginKey) return

    const pluginKey = getPluginKey(plugin, marketplace)
    setBusyPluginKey(pluginKey)
    setActionError(null)

    try {
      if (plugin.installed) {
        await http.post(`/api/sessions/${sessionId}/plugins/uninstall`, {
          plugin_id: plugin.id || plugin.name,
          force_remote_sync: true,
        })
      } else {
        await http.post(`/api/sessions/${sessionId}/plugins/install`, {
          marketplace_path: marketplace?.path || marketplace?.name || '',
          plugin_name: plugin.name || plugin.id,
          force_remote_sync: true,
        })
      }

      await Promise.allSettled([refreshSkills(), refreshCatalog()])
    } catch (err) {
      setActionError(err.message)
      console.warn('[skills] plugin action failed:', err.message)
    } finally {
      setBusyPluginKey(null)
    }
  }

  const normalizedSearch = search.trim().toLowerCase()

  const filteredSkills = skills.filter((skill) => skillMatches(skill, normalizedSearch))
  const filteredMarketplaces = marketplaces
    .map((marketplace) => ({
      ...marketplace,
      plugins: marketplace.plugins.filter((plugin) => pluginMatches(plugin, marketplace, normalizedSearch)),
    }))
    .filter((marketplace) => normalizedSearch ? marketplace.plugins.length > 0 : true)

  const totalPlugins = marketplaces.reduce((sum, marketplace) => sum + marketplace.plugins.length, 0)
  const installedPlugins = marketplaces.reduce(
    (sum, marketplace) => sum + marketplace.plugins.filter((plugin) => plugin.installed).length,
    0,
  )
  const installedSkills = skills.length

  const visiblePlugins = filteredMarketplaces.reduce((sum, marketplace) => sum + marketplace.plugins.length, 0)
  const visibleInstalledSkills = filteredSkills.length

  return (
    <div class={styles.panel}>
      <section class={styles.hero}>
        <div class={styles.heroBackdrop} aria-hidden="true" />
        <div class={styles.heroContent}>
          <div class={styles.heroEyebrow}>Plugin marketplace</div>
          <h2 class={styles.heroTitle}>Browse plugins, keep installed skills in sync.</h2>
          <p class={styles.heroCopy}>
            The current session can install marketplace plugins without leaving the capability drawer.
            Installed skills stay visible below and refresh automatically after every change.
          </p>

          <div class={styles.heroStats}>
            <StatCard value={skillsLoading ? '...' : installedSkills} label="Installed skills" />
            <StatCard value={catalogLoading ? '...' : installedPlugins} label="Installed plugins" />
            <StatCard value={catalogLoading ? '...' : marketplaces.length} label="Marketplaces" />
            <StatCard value={catalogLoading ? '...' : totalPlugins} label="Available plugins" />
          </div>
        </div>
      </section>

      {actionError && (
        <div class={styles.errorState} role="alert">
          <Badge variant="status" color="feedback-negative">Action failed</Badge>
          <span>{actionError}</span>
        </div>
      )}

      {(remoteSyncError || catalogError) && (
        <div class={styles.noticeState} role="status">
          <Badge variant="status" color={catalogError ? 'feedback-negative' : 'feedback-warning'}>
            {catalogError ? 'Catalog error' : 'Remote sync'}
          </Badge>
          <span>{catalogError || remoteSyncError}</span>
        </div>
      )}

      <section class={styles.section}>
        <div class={styles.sectionHeader}>
          <div>
            <div class={styles.sectionKicker}>Installed skills</div>
            <h3 class={styles.sectionTitle}>Session skills</h3>
          </div>
          <div class={styles.sectionMeta}>
            {skillsLoading ? 'Loading...' : `${visibleInstalledSkills} visible`}
          </div>
        </div>

        <label class={styles.searchRow}>
          <span class={styles.searchLabel}>Search</span>
          <input
            class={styles.searchInput}
            type="search"
            value={search}
            onInput={(e) => setSearch(e.currentTarget.value)}
            placeholder="Search installed skills or plugins"
            aria-label="Search installed skills or plugins"
          />
        </label>

        {skillsLoading && (
          <div class={styles.loadingState}>
            <Spinner size="md" />
            <span>Loading installed skills...</span>
          </div>
        )}

        {!skillsLoading && skillsError && (
          <div class={styles.errorState} role="alert">
            <Badge variant="status" color="feedback-negative">Skills error</Badge>
            <span>{skillsError}</span>
          </div>
        )}

        {!skillsLoading && !skillsError && filteredSkills.length === 0 && (
          <div class={styles.emptyState}>
            {search.trim()
              ? 'No installed skills match that search.'
              : 'No skills are installed for this session yet.'}
          </div>
        )}

        {!skillsLoading && filteredSkills.length > 0 && (
          <div class={styles.skillList}>
            {filteredSkills.map((skill, index) => (
              <SkillRow
                key={getSkillKey(skill, index)}
                skill={skill}
                onToggle={handleToggle}
              />
            ))}
          </div>
        )}
      </section>

      <section class={styles.section}>
        <div class={styles.sectionHeader}>
          <div>
            <div class={styles.sectionKicker}>Marketplace</div>
            <h3 class={styles.sectionTitle}>Available plugins</h3>
          </div>
          <div class={styles.sectionMeta}>
            {catalogLoading ? 'Loading...' : `${visiblePlugins} visible`}
          </div>
        </div>

        {catalogLoading && (
          <div class={styles.loadingState}>
            <Spinner size="md" />
            <span>Loading plugin marketplaces...</span>
          </div>
        )}

        {!catalogLoading && !catalogError && filteredMarketplaces.length === 0 && (
          <div class={styles.emptyState}>
            {search.trim()
              ? 'No plugins match your search.'
              : 'No plugin marketplaces are available for this session.'}
          </div>
        )}

        {!catalogLoading && filteredMarketplaces.length > 0 && (
          <div class={styles.marketplaceList}>
            {filteredMarketplaces.map((marketplace) => {
              const marketplaceInstalled = marketplace.plugins.filter((plugin) => plugin.installed).length
              const marketplaceAccent = marketplace?.interface?.brand_color

              return (
                <section
                  key={marketplace.__key}
                  class={styles.marketplaceCard}
                  style={marketplaceAccent ? { '--marketplace-accent': marketplaceAccent } : undefined}
                >
                  <header class={styles.marketplaceHeader}>
                    <div class={styles.marketplaceTitleGroup}>
                      <div class={styles.marketplaceEyebrow}>Marketplace</div>
                      <h4 class={styles.marketplaceTitle}>{marketplaceDisplayName(marketplace)}</h4>
                      {marketplaceDescription(marketplace) && (
                        <p class={styles.marketplaceDescription}>{marketplaceDescription(marketplace)}</p>
                      )}
                    </div>

                    <div class={styles.marketplaceMeta}>
                      <Badge variant="meta">{marketplace.plugins.length} plugins</Badge>
                      <Badge variant="status" color={marketplaceInstalled > 0 ? 'feedback-positive' : 'status-ended'}>
                        {marketplaceInstalled} installed
                      </Badge>
                      {marketplace?.path && <Badge variant="meta">{marketplace.path}</Badge>}
                    </div>
                  </header>

                  <div class={styles.pluginGrid}>
                    {marketplace.plugins.map((plugin, index) => (
                      <PluginCard
                        key={getPluginKey(plugin, marketplace, index)}
                        plugin={plugin}
                        marketplace={marketplace}
                        onAction={handlePluginAction}
                        busy={busyPluginKey === getPluginKey(plugin, marketplace, index)}
                      />
                    ))}
                  </div>
                </section>
              )
            })}
          </div>
        )}
      </section>
    </div>
  )
}

export { SkillsPanel }
