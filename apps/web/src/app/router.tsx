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
  LoginPage,
} from '../features/auth/LoginPage'
import {
  MessageDetailPage,
} from '../features/messages/MessageDetailPage'
import {
  MessagesPage,
} from '../features/messages/MessagesPage'
import {
  ProfilePage,
} from '../features/profile/ProfilePage'
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
import {
  TemplatesPage,
} from '../features/templates/TemplatesPage'
import {
  ContactsPage,
} from '../features/contacts/ContactsPage'
import {
  CampaignsPage,
} from '../features/campaigns/CampaignsPage'
import {
  SuppressionsPage,
} from '../features/suppressions/SuppressionsPage'

export const router =
  createBrowserRouter([
    {
      path: '/login',
      element: <LoginPage />,
    },
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
          path: 'templates',
          element: <TemplatesPage />,
        },
        {
          path: 'contacts',
          element: <ContactsPage />,
        },
        {
          path: 'campaigns',
          element: <CampaignsPage />,
        },
        {
          path: 'suppressions',
          element: <SuppressionsPage />,
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
          path: 'profile',
          element: <ProfilePage />,
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
