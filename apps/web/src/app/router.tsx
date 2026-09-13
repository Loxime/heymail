import {
  createBrowserRouter,
} from 'react-router-dom'

import {
  AppShell,
} from '../components/layout/AppShell'
import {
  DashboardPage,
} from '../features/dashboard/DashboardPage'
import {
  MessageDetailPage,
} from '../features/messages/MessageDetailPage'
import {
  MessagesPage,
} from '../features/messages/MessagesPage'

function PlaceholderPage({
  eyebrow,
  title,
}: {
  eyebrow: string
  title: string
}) {
  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            {eyebrow}
          </span>

          <h1>
            {title}
          </h1>

          <p>
            This workspace is ready for
            the next HeyMail frontend
            sprint.
          </p>
        </div>
      </header>

      <section className="panel empty-panel">
        <strong>
          {title}
        </strong>

        <span>
          Coming next.
        </span>
      </section>
    </div>
  )
}

export const router =
  createBrowserRouter([
    {
      path: '/',
      element: <AppShell />,

      children: [
        {
          index: true,
          element: <DashboardPage />,
        },

        {
          path: 'messages',
          element: <MessagesPage />,
        },

        {
          path: 'messages/:id',
          element: <MessageDetailPage />,
        },

        {
          path: 'send',
          element: (
            <PlaceholderPage
              eyebrow="Transactional"
              title="Send API"
            />
          ),
        },

        {
          path: 'domains',
          element: (
            <PlaceholderPage
              eyebrow="Configuration"
              title="Domains"
            />
          ),
        },

        {
          path: 'senders',
          element: (
            <PlaceholderPage
              eyebrow="Configuration"
              title="Sender identities"
            />
          ),
        },

        {
          path: 'webhooks',
          element: (
            <PlaceholderPage
              eyebrow="Configuration"
              title="Webhooks"
            />
          ),
        },

        {
          path: 'credentials',
          element: (
            <PlaceholderPage
              eyebrow="Developer"
              title="API credentials"
            />
          ),
        },

        {
          path: 'docs',
          element: (
            <PlaceholderPage
              eyebrow="Developer"
              title="Documentation"
            />
          ),
        },

        {
          path: 'settings',
          element: (
            <PlaceholderPage
              eyebrow="Account"
              title="Settings"
            />
          ),
        },
      ],
    },
  ])
