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
  useState,
} from 'react'
import {
  NavLink,
  Outlet,
} from 'react-router-dom'

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
            className="nav-item"
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

          <div className="topbar__environment">
            <Activity size={16} />

            <span>
              API connected
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
