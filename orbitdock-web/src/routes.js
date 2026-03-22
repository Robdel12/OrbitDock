import { DashboardPage } from './pages/dashboard.jsx'
import { MissionDetailPage } from './pages/mission-detail.jsx'
import { MissionsPage } from './pages/missions.jsx'
import { NotFoundPage } from './pages/not-found.jsx'
import { SessionPage } from './pages/session.jsx'
import { SettingsPage } from './pages/settings.jsx'
import { WorktreesPage } from './pages/worktrees.jsx'

const routes = [
  { path: '/', component: DashboardPage, label: 'Sessions', icon: 'LayoutDashboard', showInNav: true },
  { path: '/missions', component: MissionsPage, label: 'Missions', icon: 'Rocket', showInNav: true },
  { path: '/missions/:id', component: MissionDetailPage, label: 'Mission Detail' },
  { path: '/worktrees', component: WorktreesPage, label: 'Worktrees', icon: 'GitBranch', showInNav: true },
  { path: '/session/:id', component: SessionPage, label: 'Session' },
  { path: '/settings', component: SettingsPage, label: 'Settings', icon: 'Settings', showInNav: true },
  { path: '/:rest*', component: NotFoundPage, label: 'Not Found' },
]

export { routes }
