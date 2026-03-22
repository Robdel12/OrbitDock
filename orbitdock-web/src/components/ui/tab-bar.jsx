import styles from './tab-bar.module.css'

const TabBar = ({ tabs, activeTab, onTabChange }) => (
  <div class={styles.tabBar} role="tablist">
    {tabs.map((tab) => (
      <button
        key={tab.id}
        role="tab"
        aria-selected={activeTab === tab.id}
        class={`${styles.tab} ${activeTab === tab.id ? styles.tabActive : ''}`}
        onClick={() => onTabChange(tab.id)}
      >
        {tab.label}
        {tab.count != null && tab.count > 0 && <span class={styles.tabCount}>{tab.count}</span>}
      </button>
    ))}
  </div>
)

export { TabBar }
