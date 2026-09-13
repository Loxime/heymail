import {
  Activity,
  BookOpen,
  Code2,
  Globe2,
  LayoutDashboard,
  Mail,
  Menu,
  Send,
  Settings,
  UserRoundCheck,
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
  NavLink,
  Outlet,
  useLocation,
} from 'react-router-dom'

import {
  apiGet,
} from '../../lib/api/client'
import type {
  DashboardResponse,
} from '../../lib/api/types'

const groups = [
  {
    label: 'Overview',

    items: [
      {
        to: '/',
        label: 'Dashboard',
        icon: LayoutDashboard,
      },
    ],
  },

  {
    label: 'Transactional',

    items: [
      {
        to: '/messages',
        label: 'Messages',
        icon: Mail,
      },
      {
        to: '/send',
        label: 'Send API',
        icon: Send,
      },
    ],
  },

  {
    label: 'Configuration',

    items: [
      {
        to: '/domains',
        label: 'Domains',
        icon: Globe2,
      },
      {
        to: '/senders',
        label: 'Sender identities',
        icon: UserRoundCheck,
      },
      {
        to: '/webhooks',
        label: 'Webhooks',
        icon: Webhook,
      },
    ],
  },

  {
    label: 'Developer',

    items: [
      {
        to: '/credentials',
        label: 'API credentials',
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

  const location =
    useLocation()

  const apiStatus =
    useQuery({
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

  useEffect(
    () => {
      setMobileNavigationOpen(
        false,
      )

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
      ? 'Connecting…'
      : apiStatus.isError
        ? 'API unavailable'
        : 'API connected'

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
          <div className="brand-mark">
            H
          </div>

          <div>
            <strong>HeyMail</strong>
            <span>Transactional email</span>
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

              {group.items.map(
                ({
                  to,
                  label,
                  icon: Icon,
                }) => (
                  <NavLink
                    className={({
                      isActive,
                    }) =>
                      isActive
                        ? 'nav-item nav-item--active'
                        : 'nav-item'
                    }
                    end={to === '/'}
                    key={to}
                    onClick={() =>
                      setMobileNavigationOpen(
                        false,
                      )
                    }
                    to={to}
                  >
                    <Icon size={18} />
                    <span>{label}</span>
                  </NavLink>
                ),
              )}
            </section>
          ))}
        </nav>

        <div className="sidebar__footer">
          <NavLink
            className={({
              isActive,
            }) =>
              isActive
                ? 'nav-item nav-item--active'
                : 'nav-item'
            }
            to="/settings"
          >
            <Settings size={18} />
            <span>Settings</span>
          </NavLink>
        </div>
      </aside>

      {mobileNavigationOpen && (
        <button
          aria-label="Close navigation"
          className="sidebar-overlay"
          onClick={() =>
            setMobileNavigationOpen(
              false,
            )
          }
          type="button"
        />
      )}

      <main className="app-main">
        <header className="topbar">
          <button
            aria-label="Open navigation"
            className="topbar__menu"
            onClick={() =>
              setMobileNavigationOpen(
                true,
              )
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

            <span>
              {apiLabel}
            </span>
          </div>

          <div className="topbar__account">
            <div className="account-avatar">
              HM
            </div>

            <div className="account-copy">
              <strong>
                HeyMail
              </strong>
              <span>
                Local console
              </span>
            </div>
          </div>
        </header>

        <div className="app-content">
          <Outlet />
        </div>
      </main>
    </div>
  )
}
