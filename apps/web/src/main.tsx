import React from 'react'
import ReactDOM from 'react-dom/client'
import {
  QueryClientProvider,
} from '@tanstack/react-query'
import {
  RouterProvider,
} from 'react-router-dom'

import { queryClient } from './app/query-client'
import { router } from './app/router'

import './styles/global.css'

const root =
  document.getElementById('root')

if (!root) {
  throw new Error(
    'HeyMail root element is missing.',
  )
}

ReactDOM
  .createRoot(root)
  .render(
    <React.StrictMode>
      <QueryClientProvider
        client={queryClient}
      >
        <RouterProvider
          router={router}
        />
      </QueryClientProvider>
    </React.StrictMode>,
  )
