import {
  AlertTriangle,
  ChevronRight,
  Filter,
  Mail,
  RefreshCw,
  Search,
} from 'lucide-react'
import {
  useInfiniteQuery,
} from '@tanstack/react-query'
import {
  Link,
} from 'react-router-dom'
import {
  useMemo,
  useState,
} from 'react'

import {
  StatusBadge,
} from '../../components/data-display/StatusBadge'
import {
  apiGet,
} from '../../lib/api/client'
import type {
  MessageListResponse,
} from '../../lib/api/types'
import {
  formatDateTime,
} from '../../lib/format/date'

interface Filters {
  status: string
  event: string
  createdAfter: string
  createdBefore: string
}

const emptyFilters: Filters = {
  status: '',
  event: '',
  createdAfter: '',
  createdBefore: '',
}

function toApiDate(
  value: string,
): string | null {
  if (value === '') {
    return null
  }

  const date =
    new Date(value)

  if (
    Number.isNaN(
      date.getTime(),
    )
  ) {
    return null
  }

  return date.toISOString()
}

export function MessagesPage() {
  const [
    draftFilters,
    setDraftFilters,
  ] = useState<Filters>(
    emptyFilters,
  )

  const [
    filters,
    setFilters,
  ] = useState<Filters>(
    emptyFilters,
  )

  const query =
    useInfiniteQuery({
      queryKey: [
        'messages',
        filters,
      ],

      initialPageParam:
        null as string | null,

      queryFn: ({
        pageParam,
      }) => {
        const search =
          new URLSearchParams({
            limit: '25',
          })

        if (pageParam) {
          search.set(
            'cursor',
            pageParam,
          )
        }

        if (filters.status) {
          search.set(
            'status',
            filters.status,
          )
        }

        if (filters.event) {
          search.set(
            'event',
            filters.event,
          )
        }

        const createdAfter =
          toApiDate(
            filters.createdAfter,
          )

        const createdBefore =
          toApiDate(
            filters.createdBefore,
          )

        if (createdAfter) {
          search.set(
            'createdAfter',
            createdAfter,
          )
        }

        if (createdBefore) {
          search.set(
            'createdBefore',
            createdBefore,
          )
        }

        return apiGet<MessageListResponse>(
          `/api/v1/messages?${search.toString()}`,
        )
      },

      getNextPageParam:
        (lastPage) =>
          lastPage.nextCursor,
    })

  const messages =
    useMemo(
      () =>
        query.data?.pages
          .flatMap(
            (page) =>
              page.items,
          )
        ?? [],
      [
        query.data,
      ],
    )

  const applyFilters = () => {
    setFilters({
      ...draftFilters,
    })
  }

  const clearFilters = () => {
    setDraftFilters({
      ...emptyFilters,
    })

    setFilters({
      ...emptyFilters,
    })
  }

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Transactional
          </span>

          <h1>
            Messages
          </h1>

          <p>
            Inspect submissions,
            delivery feedback and SMTP
            outcomes.
          </p>
        </div>

        <button
          className="button button--secondary"
          onClick={() =>
            query.refetch()
          }
          type="button"
        >
          <RefreshCw size={14} />
          Refresh
        </button>
      </header>

      <section className="panel message-filters">
        <div className="message-filters__heading">
          <Filter size={15} />

          <strong>
            Filters
          </strong>
        </div>

        <div className="message-filters__grid">
          <label className="field">
            <span>Status</span>

            <select
              onChange={(event) =>
                setDraftFilters(
                  (current) => ({
                    ...current,
                    status:
                      event
                        .target
                        .value,
                  }),
                )
              }
              value={
                draftFilters.status
              }
            >
              <option value="">
                All statuses
              </option>

              <option value="queued">
                Queued
              </option>

              <option value="ready_for_submission">
                Ready for submission
              </option>

              <option value="submitting">
                Submitting
              </option>

              <option value="submission_uncertain">
                Submission uncertain
              </option>

              <option value="submitted">
                Submitted
              </option>
            </select>
          </label>

          <label className="field">
            <span>Event</span>

            <select
              onChange={(event) =>
                setDraftFilters(
                  (current) => ({
                    ...current,
                    event:
                      event
                        .target
                        .value,
                  }),
                )
              }
              value={
                draftFilters.event
              }
            >
              <option value="">
                All events
              </option>

              <option value="queued">
                Queued
              </option>

              <option value="submitted">
                Submitted
              </option>

              <option value="delivered">
                Delivered
              </option>

              <option value="tempfail">
                Tempfail
              </option>

              <option value="bounced">
                Bounced
              </option>

              <option value="submission_uncertain">
                Submission uncertain
              </option>
            </select>
          </label>

          <label className="field">
            <span>Created after</span>

            <input
              onChange={(event) =>
                setDraftFilters(
                  (current) => ({
                    ...current,
                    createdAfter:
                      event
                        .target
                        .value,
                  }),
                )
              }
              type="datetime-local"
              value={
                draftFilters
                  .createdAfter
              }
            />
          </label>

          <label className="field">
            <span>Created before</span>

            <input
              onChange={(event) =>
                setDraftFilters(
                  (current) => ({
                    ...current,
                    createdBefore:
                      event
                        .target
                        .value,
                  }),
                )
              }
              type="datetime-local"
              value={
                draftFilters
                  .createdBefore
              }
            />
          </label>
        </div>

        <div className="message-filters__actions">
          <button
            className="button button--ghost"
            onClick={
              clearFilters
            }
            type="button"
          >
            Clear
          </button>

          <button
            className="button button--primary button--inline"
            onClick={
              applyFilters
            }
            type="button"
          >
            <Search size={14} />
            Apply filters
          </button>
        </div>
      </section>

      <section className="panel messages-panel">
        <header className="panel__header panel__header--row">
          <div>
            <h2>
              Transactional messages
            </h2>

            <p>
              {messages.length}
              {' '}
              loaded
            </p>
          </div>
        </header>

        {query.isLoading && (
          <MessagesTableSkeleton />
        )}

        {query.isError && (
          <div className="state-card state-card--embedded">
            <AlertTriangle size={21} />

            <div>
              <strong>
                Messages unavailable
              </strong>

              <p>
                {query.error
                  instanceof Error
                  ? query
                      .error
                      .message
                  : 'Unable to load messages.'}
              </p>
            </div>
          </div>
        )}

        {!query.isLoading
          && !query.isError
          && messages.length === 0
          && (
            <div className="empty-state">
              <div className="empty-state__icon">
                <Mail size={22} />
              </div>

              <strong>
                No messages found
              </strong>

              <span>
                Change the filters or
                send a new transactional
                message.
              </span>
            </div>
          )}

        {messages.length > 0 && (
          <>
            <div className="table-scroll">
              <table className="data-table message-table">
                <thead>
                  <tr>
                    <th>Message</th>
                    <th>Status</th>
                    <th>Created</th>
                    <th>Delivered</th>
                    <th>Tempfail</th>
                    <th>Bounced</th>
                    <th />
                  </tr>
                </thead>

                <tbody>
                  {messages.map(
                    (message) => (
                      <tr
                        key={
                          message
                            .messageId
                        }
                      >
                        <td>
                          <Link
                            className="message-id"
                            to={
                              `/messages/${message.messageId}`
                            }
                          >
                            #
                            {
                              message
                                .messageId
                            }
                          </Link>
                        </td>

                        <td>
                          <StatusBadge
                            status={
                              message.status
                            }
                          />
                        </td>

                        <td className="table-muted">
                          {formatDateTime(
                            message
                              .createdAt,
                          )}
                        </td>

                        <td>
                          <DeliveryMetric
                            tone="success"
                            value={
                              message
                                .deliverySummary
                                .delivered
                            }
                          />
                        </td>

                        <td>
                          <DeliveryMetric
                            tone="warning"
                            value={
                              message
                                .deliverySummary
                                .tempfail
                            }
                          />
                        </td>

                        <td>
                          <DeliveryMetric
                            tone="danger"
                            value={
                              message
                                .deliverySummary
                                .bounced
                            }
                          />
                        </td>

                        <td className="message-table__open">
                          <Link
                            aria-label={
                              `Open message ${message.messageId}`
                            }
                            className="icon-link"
                            to={
                              `/messages/${message.messageId}`
                            }
                          >
                            <ChevronRight size={16} />
                          </Link>
                        </td>
                      </tr>
                    ),
                  )}
                </tbody>
              </table>
            </div>

            {query.hasNextPage && (
              <div className="load-more">
                <button
                  className="button button--secondary"
                  disabled={
                    query
                      .isFetchingNextPage
                  }
                  onClick={() =>
                    query
                      .fetchNextPage()
                  }
                  type="button"
                >
                  {query
                    .isFetchingNextPage
                    ? 'Loading…'
                    : 'Load more'}
                </button>
              </div>
            )}
          </>
        )}
      </section>
    </div>
  )
}

function DeliveryMetric({
  value,
  tone,
}: {
  value: number
  tone: 'success'
    | 'warning'
    | 'danger'
}) {
  return (
    <span
      className={
        `delivery-metric delivery-metric--${tone}`
      }
    >
      {value}
    </span>
  )
}

function MessagesTableSkeleton() {
  return (
    <div className="message-table-skeleton">
      {Array.from({
        length: 7,
      }).map((_, index) => (
        <div
          className="skeleton message-table-skeleton__row"
          key={index}
        />
      ))}
    </div>
  )
}
