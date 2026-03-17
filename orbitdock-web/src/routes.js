import { DashboardPage } from './pages/dashboard.jsx'
import { SessionPage } from './pages/session.jsx'
import { SettingsPage } from './pages/settings.jsx'
import { MissionsPage } from './pages/missions.jsx'
import { MissionDetailPage } from './pages/mission-detail.jsx'
import { NotFoundPage } from './pages/not-found.jsx'

const routes = [
  { path: '/', component: DashboardPage, label: 'Sessions', icon: 'LayoutDashboard', showInNav: true },
  { path: '/missions', component: MissionsPage, label: 'Missions', icon: 'Rocket', showInNav: true },
  { path: '/missions/:id', component: MissionDetailPage, label: 'Mission Detail' },
  { path: '/session/:id', component: SessionPage, label: 'Session' },
  { path: '/settings', component: SettingsPage, label: 'Settings', icon: 'Settings', showInNav: true },
  { path: '/:rest*', component: NotFoundPage, label: 'Not Found' },
]

export { routes }
