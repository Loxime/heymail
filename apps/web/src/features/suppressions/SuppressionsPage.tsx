import {
  Ban,
  Plus,
  Trash2,
} from 'lucide-react'
import {
  useMutation,
  useQuery,
  useQueryClient,
} from '@tanstack/react-query'
import {
  useState,
} from 'react'

import {
  apiDelete,
  apiGet,
  apiPost,
} from '../../lib/api/client'
import type {
  ConsoleContactListListResponse,
  ConsoleSuppression,
  ConsoleSuppressionListResponse,
} from '../../lib/api/types'

export function SuppressionsPage() {
  const queryClient = useQueryClient()

  const suppressions = useQuery({
    queryKey: ['console-suppressions'],
    queryFn: () =>
      apiGet<ConsoleSuppressionListResponse>(
        '/console/suppressions',
      ),
  })

  const lists = useQuery({
    queryKey: ['console-contact-lists'],
    queryFn: () =>
      apiGet<ConsoleContactListListResponse>(
        '/console/contact-lists',
      ),
  })

  const [email, setEmail] =
    useState('')
  const [scope, setScope] =
    useState<'global' | 'list'>('global')
  const [listId, setListId] =
    useState('')
  const [error, setError] =
    useState<string | null>(null)

  const refresh = async () => {
    await queryClient.invalidateQueries({
      queryKey: ['console-suppressions'],
    })
  }

  const create = useMutation({
    mutationFn: () =>
      apiPost<ConsoleSuppression>(
        '/console/suppressions',
        {
          email: email.trim(),
          ...(scope === 'list'
            ? {
                listId: Number(listId),
              }
            : {}),
        },
      ),
    onSuccess: async () => {
      setEmail('')
      setError(null)
      await refresh()
    },
    onError: (caught) =>
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to create suppression.',
      ),
  })

  const remove = useMutation({
    mutationFn: (id: number) =>
      apiDelete<void>(
        `/console/suppressions/${id}`,
      ),
    onSuccess: async () => {
      setError(null)
      await refresh()
    },
    onError: (caught) =>
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to remove suppression.',
      ),
  })

  const items =
    suppressions.data?.items ?? []

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Deliverability
          </span>
          <h1>Suppressions</h1>
          <p>
            Block recipients globally or for
            one contact list. Hard bounces and
            unsubscribe requests appear here
            automatically.
          </p>
        </div>
      </header>

      {error && (
        <div className="inline-error">
          {error}
        </div>
      )}

      <div className="suppression-grid">
        <section className="panel">
          <header className="panel__header">
            <div>
              <h2>
                <Plus size={15} />
                Add suppression
              </h2>
            </div>
          </header>

          <div className="suppression-form">
            <label className="field">
              <span>Email</span>
              <input
                onChange={(event) =>
                  setEmail(
                    event.target.value,
                  )
                }
                type="email"
                value={email}
              />
            </label>

            <label className="field">
              <span>Scope</span>
              <select
                onChange={(event) =>
                  setScope(
                    event.target.value as
                      | 'global'
                      | 'list',
                  )
                }
                value={scope}
              >
                <option value="global">
                  Global
                </option>
                <option value="list">
                  One list
                </option>
              </select>
            </label>

            {scope === 'list' && (
              <label className="field">
                <span>List</span>
                <select
                  onChange={(event) =>
                    setListId(
                      event.target.value,
                    )
                  }
                  value={listId}
                >
                  <option value="">
                    Select list…
                  </option>
                  {lists.data?.items.map(
                    (list) => (
                      <option
                        key={list.id}
                        value={list.id}
                      >
                        {list.name}
                      </option>
                    ),
                  )}
                </select>
              </label>
            )}

            <button
              className="button button--primary"
              disabled={
                email.trim() === ''
                || (
                  scope === 'list'
                  && listId === ''
                )
                || create.isPending
              }
              onClick={() =>
                create.mutate()
              }
              type="button"
            >
              <Ban size={13} />
              Suppress
            </button>
          </div>
        </section>

        <section className="panel">
          <header className="panel__header">
            <div>
              <h2>Active suppressions</h2>
              <p>{items.length} entries</p>
            </div>
          </header>

          <div className="suppression-list">
            {items.map((item) => (
              <div
                className="suppression-row"
                key={item.id}
              >
                <div>
                  <strong>{item.email}</strong>
                  <span>
                    {item.scope}
                    {' · '}
                    {item.reason}
                    {item.listId === null
                      ? ''
                      : ` · list #${item.listId}`}
                  </span>
                </div>

                <button
                  aria-label={`Remove ${item.email}`}
                  className="icon-button"
                  disabled={remove.isPending}
                  onClick={() =>
                    remove.mutate(
                      item.id,
                    )
                  }
                  type="button"
                >
                  <Trash2 size={15} />
                </button>
              </div>
            ))}

            {!suppressions.isLoading
              && items.length === 0 && (
                <div className="template-empty">
                  No suppressions.
                </div>
              )}
          </div>
        </section>
      </div>
    </div>
  )
}
