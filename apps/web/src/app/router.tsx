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
import {
  SendApiPage,
} from '../features/send/SendApiPage'
import {
  DomainsPage,
} from '../features/domains/DomainsPage'
import {
  SendersPage,
} from '../features/senders/SendersPage'
import {
  CredentialsPage,
} from '../features/developer/CredentialsPage'
import {
  DocumentationPage,
} from '../features/developer/DocumentationPage'
import {
  SettingsPage,
} from '../features/settings/SettingsPage'
import {
  NotFoundPage,
} from '../features/system/NotFoundPage'
import {
  WebhooksPage,
} from '../features/webhooks/WebhooksPage'

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
          element: <SendApiPage />,
        },

        {
          path: 'domains',
          element: <DomainsPage />,
        },

        {
          path: 'senders',
          element: <SendersPage />,
        },

        {
          path: 'webhooks',
          element: <WebhooksPage />,
        },

        {
          path: 'credentials',
          element: <CredentialsPage />,
        },

        {
          path: 'docs',
          element: <DocumentationPage />,
        },

        {
          path: 'settings',
          element: <SettingsPage />,
        },

        {
          path: '*',
          element: <NotFoundPage />,
        },
      ],
    },
  ])
