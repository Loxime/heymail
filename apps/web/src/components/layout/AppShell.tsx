import {
  Activity,
  BookOpen,
  Code2,
  Globe2,
  LayoutDashboard,
  FileText,
  Mail,
  Megaphone,
  Menu,
  Send,
  Settings,
  ShieldOff,
  UserRound,
  UserRoundCheck,
  Users,
  Webhook,
} from 'lucide-react'
import {
  useEffect,
  useState,
} from 'react'
import {
  useQuery,
} from '@tanstack/react-query'
import {
  Link,
  NavLink,
  Outlet,
  useLocation,
} from 'react-router-dom'

import {
  apiGet,
} from '../../lib/api/client'
import type {
  ConsoleSessionResponse,
  DashboardResponse,
} from '../../lib/api/types'

const groups = [
  {
    label: 'Vue d’ensemble',
    items: [
      {
        to: '/',
        label: 'Tableau de bord',
        icon: LayoutDashboard,
      },
    ],
  },
  {
    label: 'Envois',
    items: [
      {
        to: '/messages',
        label: 'Messages',
        icon: Mail,
      },
      {
        to: '/send',
        label: 'Envoyer un email',
        icon: Send,
      },
      {
        to: '/templates',
        label: 'Templates',
        icon: FileText,
      },
      {
        to: '/contacts',
        label: 'Contacts',
        icon: Users,
      },
      {
        to: '/campaigns',
        label: 'Campagnes',
        icon: Megaphone,
      },
    ],
  },
  {
    label: 'Configuration',
    items: [
      {
        to: '/domains',
        label: 'Domaines',
        icon: Globe2,
      },
      {
        to: '/senders',
        label: 'Expéditeurs',
        icon: UserRoundCheck,
      },
      {
        to: '/webhooks',
        label: 'Webhooks',
        icon: Webhook,
      },
      {
        to: '/suppressions',
        label: 'Suppressions',
        icon: ShieldOff,
      },
    ],
  },
  {
    label: 'Développeur',
    items: [
      {
        to: '/credentials',
        label: 'Clés API',
        icon: Code2,
      },
      {
        to: '/docs',
        label: 'Documentation',
        icon: BookOpen,
      },
    ],
  },
]

export function AppShell() {
  const [
    mobileNavigationOpen,
    setMobileNavigationOpen,
  ] = useState(false)

  const location = useLocation()

  const apiStatus = useQuery({
    queryKey: [
      'dashboard',
    ],
    queryFn: () =>
      apiGet<DashboardResponse>(
        '/api/v1/dashboard',
      ),
    refetchInterval: 30_000,
    retry: false,
  })

  const session = useQuery({
    queryKey: [
      'console-session',
    ],
    queryFn: () =>
      apiGet<ConsoleSessionResponse>(
        '/console/auth/session',
      ),
    retry: false,
  })

  useEffect(
    () => {
      setMobileNavigationOpen(false)
      window.scrollTo({
        top: 0,
        behavior: 'auto',
      })
    },
    [
      location.pathname,
    ],
  )

  const apiLabel =
    apiStatus.isPending
      ? 'Connexion…'
      : apiStatus.isError
        ? 'API indisponible'
        : 'API connectée'

  const displayName =
    session.data
      ? `${session.data.user.firstName} ${session.data.user.lastName}`
      : 'Compte HeyMail'

  return (
    <div className="app-shell">
      <aside
        className={
          mobileNavigationOpen
            ? 'sidebar sidebar--open'
            : 'sidebar'
        }
      >
        <div className="sidebar__brand">
          <div className="brand-mark brand-mark--logo">
            <img
              alt=""
              aria-hidden="true"
              src="/heymail-logo.svg"
            />
          </div>

          <div>
            <strong>HeyMail</strong>
            <span>Email platform</span>
          </div>
        </div>

        <nav className="sidebar__navigation">
          {groups.map((group) => (
            <section
              className="nav-group"
              key={group.label}
            >
              <span className="nav-group__label">
                {group.label}
              </span>

              {group.items.map(({
                to,
                label,
                icon: Icon,
              }) => (
                <NavLink
                  className={({ isActive }) =>
                    isActive
                      ? 'nav-item nav-item--active'
                      : 'nav-item'
                  }
                  end={to === '/'}
                  key={to}
                  onClick={() =>
                    setMobileNavigationOpen(false)
                  }
                  to={to}
                >
                  <Icon size={18} />
                  <span>{label}</span>
                </NavLink>
              ))}
            </section>
          ))}
        </nav>

        <div className="sidebar__footer">
          <NavLink
            className={({ isActive }) =>
              isActive
                ? 'nav-item nav-item--active'
                : 'nav-item'
            }
            to="/profile"
          >
            <UserRound size={18} />
            <span>Profil</span>
          </NavLink>

          <NavLink
            className={({ isActive }) =>
              isActive
                ? 'nav-item nav-item--active'
                : 'nav-item'
            }
            to="/settings"
          >
            <Settings size={18} />
            <span>Paramètres</span>
          </NavLink>
        </div>
      </aside>

      {mobileNavigationOpen && (
        <button
          aria-label="Fermer la navigation"
          className="sidebar-overlay"
          onClick={() =>
            setMobileNavigationOpen(false)
          }
          type="button"
        />
      )}

      <main className="app-main">
        <header className="topbar">
          <button
            aria-label="Ouvrir la navigation"
            className="topbar__menu"
            onClick={() =>
              setMobileNavigationOpen(true)
            }
            type="button"
          >
            <Menu size={20} />
          </button>

          <div
            aria-live="polite"
            className={
              apiStatus.isError
                ? 'topbar__environment topbar__environment--offline'
                : 'topbar__environment'
            }
          >
            <Activity size={16} />
            <span>{apiLabel}</span>
          </div>

          <Link
            className="topbar__account"
            to="/profile"
          >
            <div className="account-avatar">
              <UserRound size={15} />
            </div>

            <div className="account-copy">
              <strong>{displayName}</strong>
              <span>Profil</span>
            </div>
          </Link>
        </header>

        <div className="app-content">
          <Outlet />
        </div>
      </main>
    </div>
  )
}
