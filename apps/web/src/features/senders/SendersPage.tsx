import {
  CheckCircle2,
  Mail,
  Plus,
  RefreshCw,
  ShieldAlert,
  UserRoundCheck,
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
  apiGet,
  apiPost,
} from '../../lib/api/client'
import type {
  SenderIdentityCreateResponse,
  SenderIdentityListResponse,
} from '../../lib/api/types'
import {
  formatDateTime,
} from '../../lib/format/date'

export function SendersPage() {
  const queryClient =
    useQueryClient()

  const [
    email,
    setEmail,
  ] = useState('')

  const senders =
    useQuery({
      queryKey: [
        'senders',
      ],

      queryFn: () =>
        apiGet<SenderIdentityListResponse>(
          '/api/v1/senders',
        ),
    })

  const createSender =
    useMutation({
      mutationFn: (
        value: string,
      ) =>
        apiPost<SenderIdentityCreateResponse>(
          '/api/v1/senders',
          {
            email: value,
          },
        ),

      onSuccess: async () => {
        setEmail('')

        await queryClient
          .invalidateQueries({
            queryKey: [
              'senders',
            ],
          })
      },
    })

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Configuration
          </span>

          <h1>
            Sender identities
          </h1>

          <p>
            Authorize exact From
            addresses on verified,
            DKIM-ready domains.
          </p>
        </div>

        <button
          className="button button--secondary"
          onClick={() =>
            senders.refetch()
          }
          type="button"
        >
          <RefreshCw size={14} />
          Refresh
        </button>
      </header>

      <section className="panel create-resource">
        <div className="create-resource__copy">
          <div className="resource-icon">
            <UserRoundCheck size={19} />
          </div>

          <div>
            <strong>
              Add sender identity
            </strong>

            <p>
              Its domain must be verified
              and DKIM-ready first.
            </p>
          </div>
        </div>

        <form
          className="create-resource__form"
          onSubmit={(event) => {
            event.preventDefault()

            const value =
              email.trim()

            if (value === '') {
              return
            }

            createSender.mutate(
              value,
            )
          }}
        >
          <input
            aria-label="Sender email"
            autoComplete="email"
            onChange={(event) =>
              setEmail(
                event.target.value,
              )
            }
            placeholder="hello@example.com"
            type="email"
            value={email}
          />

          <button
            className="button button--primary button--inline"
            disabled={
              createSender.isPending
              || email.trim() === ''
            }
            type="submit"
          >
            <Plus size={14} />
            Add sender
          </button>
        </form>
      </section>

      {createSender.error
        instanceof Error && (
          <div className="inline-error">
            {createSender.error.message}
          </div>
        )}

      {senders.isError && (
        <div className="inline-error">
          {senders.error
            instanceof Error
            ? senders.error.message
            : 'Unable to load senders.'}
        </div>
      )}

      <section className="panel">
        <header className="panel__header panel__header--row">
          <div>
            <h2>
              Authorized senders
            </h2>

            <p>
              Exact From identities
              accepted by the send API.
            </p>
          </div>
        </header>

        {senders.isLoading && (
          <div className="message-table-skeleton">
            {Array.from({
              length: 5,
            }).map((_, index) => (
              <div
                className="skeleton message-table-skeleton__row"
                key={index}
              />
            ))}
          </div>
        )}

        {senders.data?.items.length
          === 0 && (
            <div className="empty-state">
              <div className="empty-state__icon">
                <Mail size={22} />
              </div>

              <strong>
                No sender identities
              </strong>

              <span>
                Verify a DKIM-ready
                domain, then register an
                exact From address.
              </span>
            </div>
          )}

        {senders.data
          && senders.data.items.length
            > 0 && (
            <div className="table-scroll">
              <table className="data-table">
                <thead>
                  <tr>
                    <th>Sender</th>
                    <th>Domain</th>
                    <th>Authorization</th>
                    <th>Created</th>
                  </tr>
                </thead>

                <tbody>
                  {senders.data.items.map(
                    (sender) => (
                      <tr
                        key={sender.id}
                      >
                        <td>
                          <div className="sender-cell">
                            <div className="sender-avatar">
                              {
                                sender.email
                                  .charAt(0)
                                  .toUpperCase()
                              }
                            </div>

                            <strong>
                              {sender.email}
                            </strong>
                          </div>
                        </td>

                        <td className="table-muted">
                          {sender.domain}
                        </td>

                        <td>
                          {sender.authorized
                            ? (
                                <span className="authorization authorization--ready">
                                  <CheckCircle2 size={13} />
                                  Authorized
                                </span>
                              )
                            : (
                                <span className="authorization authorization--blocked">
                                  <ShieldAlert size={13} />
                                  Blocked
                                </span>
                              )}
                        </td>

                        <td className="table-muted">
                          {formatDateTime(
                            sender.createdAt,
                          )}
                        </td>
                      </tr>
                    ),
                  )}
                </tbody>
              </table>
            </div>
          )}
      </section>
    </div>
  )
}
