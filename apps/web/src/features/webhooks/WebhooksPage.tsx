import {
  AlertTriangle,
  Check,
  Clipboard,
  GlobeLock,
  Plus,
  RefreshCw,
  ShieldCheck,
  Webhook,
  X,
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
  WebhookCreateResponse,
  WebhookEndpoint,
  WebhookEventType,
  WebhookListResponse,
} from '../../lib/api/types'
import {
  formatDateTime,
} from '../../lib/format/date'

const webhookEvents: Array<{
  value: WebhookEventType
  label: string
  description: string
}> = [
  {
    value: 'delivered',
    label: 'Delivered',
    description:
      'Recipient accepted the message.',
  },
  {
    value: 'tempfail',
    label: 'Tempfail',
    description:
      'Temporary SMTP delivery failure.',
  },
  {
    value: 'bounced',
    label: 'Bounced',
    description:
      'Permanent recipient failure.',
  },
]

export function WebhooksPage() {
  const queryClient =
    useQueryClient()

  const [
    url,
    setUrl,
  ] = useState('')

  const [
    events,
    setEvents,
  ] = useState<WebhookEventType[]>([
    'delivered',
  ])

  const [
    createdWebhook,
    setCreatedWebhook,
  ] =
    useState<WebhookCreateResponse | null>(
      null,
    )

  const webhooks =
    useQuery({
      queryKey: [
        'webhooks',
      ],

      queryFn: () =>
        apiGet<WebhookListResponse>(
          '/api/v1/webhooks',
        ),
    })

  const createWebhook =
    useMutation({
      mutationFn: () =>
        apiPost<WebhookCreateResponse>(
          '/api/v1/webhooks',
          {
            url: url.trim(),
            events,
          },
        ),

      onSuccess: async (
        response,
      ) => {
        setCreatedWebhook(
          response,
        )

        setUrl('')

        setEvents([
          'delivered',
        ])

        await queryClient
          .invalidateQueries({
            queryKey: [
              'webhooks',
            ],
          })
      },
    })

  const toggleEvent = (
    event: WebhookEventType,
  ) => {
    setEvents(
      (current) => {
        if (
          current.includes(
            event,
          )
        ) {
          if (
            current.length === 1
          ) {
            return current
          }

          return current.filter(
            (candidate) =>
              candidate !== event,
          )
        }

        return [
          ...current,
          event,
        ]
      },
    )
  }

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Configuration
          </span>

          <h1>
            Webhooks
          </h1>

          <p>
            Receive signed HTTPS events
            for recipient delivery
            outcomes.
          </p>
        </div>

        <button
          className="button button--secondary"
          onClick={() =>
            webhooks.refetch()
          }
          type="button"
        >
          <RefreshCw size={14} />
          Refresh
        </button>
      </header>

      <section className="panel webhook-create">
        <div className="webhook-create__header">
          <div className="resource-icon">
            <Webhook size={18} />
          </div>

          <div>
            <strong>
              Create webhook endpoint
            </strong>

            <p>
              HTTPS only. HeyMail signs
              every request with your
              endpoint secret.
            </p>
          </div>
        </div>

        <form
          onSubmit={(event) => {
            event.preventDefault()

            if (
              url.trim() === ''
              || events.length === 0
            ) {
              return
            }

            createWebhook.mutate()
          }}
        >
          <label className="field">
            <span>
              Endpoint URL
            </span>

            <div className="webhook-url-field">
              <GlobeLock size={15} />

              <input
                autoComplete="off"
                onChange={(event) =>
                  setUrl(
                    event
                      .target
                      .value,
                  )
                }
                placeholder="https://example.com/webhooks/heymail"
                spellCheck={false}
                type="url"
                value={url}
              />
            </div>
          </label>

          <div className="webhook-events">
            <span className="webhook-events__label">
              Events
            </span>

            <div className="webhook-events__grid">
              {webhookEvents.map(
                (event) => {
                  const selected =
                    events.includes(
                      event.value,
                    )

                  return (
                    <button
                      className={
                        selected
                          ? 'webhook-event webhook-event--selected'
                          : 'webhook-event'
                      }
                      key={
                        event.value
                      }
                      onClick={() =>
                        toggleEvent(
                          event.value,
                        )
                      }
                      type="button"
                    >
                      <span className="webhook-event__check">
                        {selected && (
                          <Check size={12} />
                        )}
                      </span>

                      <span>
                        <strong>
                          {
                            event.label
                          }
                        </strong>

                        <small>
                          {
                            event.description
                          }
                        </small>
                      </span>
                    </button>
                  )
                },
              )}
            </div>
          </div>

          {createWebhook.error
            instanceof Error && (
              <div className="inline-error webhook-create__error">
                {
                  createWebhook
                    .error
                    .message
                }
              </div>
            )}

          <div className="webhook-create__actions">
            <button
              className="button button--primary button--inline"
              disabled={
                createWebhook.isPending
                || url.trim() === ''
                || events.length === 0
              }
              type="submit"
            >
              <Plus size={14} />

              {createWebhook.isPending
                ? 'Creating…'
                : 'Create webhook'}
            </button>
          </div>
        </form>
      </section>

      {createdWebhook && (
        <WebhookSecretCard
          webhook={
            createdWebhook
          }
          onDismiss={() =>
            setCreatedWebhook(
              null,
            )
          }
        />
      )}

      <section className="panel">
        <header className="panel__header panel__header--row">
          <div>
            <h2>
              Endpoints
            </h2>

            <p>
              Active webhook
              subscriptions.
            </p>
          </div>
        </header>

        {webhooks.isLoading && (
          <div className="message-table-skeleton">
            {Array.from({
              length: 4,
            }).map((_, index) => (
              <div
                className="skeleton message-table-skeleton__row"
                key={index}
              />
            ))}
          </div>
        )}

        {webhooks.isError && (
          <div className="inline-error webhook-list-error">
            {webhooks.error
              instanceof Error
              ? webhooks.error.message
              : 'Unable to load webhooks.'}
          </div>
        )}

        {webhooks.data?.items.length
          === 0 && (
          <div className="empty-state">
            <div className="empty-state__icon">
              <Webhook size={22} />
            </div>

            <strong>
              No webhook endpoints
            </strong>

            <span>
              Create your first endpoint
              to receive delivery events.
            </span>
          </div>
        )}

        {webhooks.data
          && webhooks.data.items.length
            > 0 && (
            <div className="webhook-list">
              {webhooks.data.items.map(
                (webhook) => (
                  <WebhookRow
                    key={
                      webhook.webhookId
                    }
                    webhook={
                      webhook
                    }
                  />
                ),
              )}
            </div>
          )}
      </section>
    </div>
  )
}

function WebhookSecretCard({
  webhook,
  onDismiss,
}: {
  webhook: WebhookCreateResponse
  onDismiss: () => void
}) {
  const [
    copied,
    setCopied,
  ] = useState(false)

  const copy = async () => {
    await navigator.clipboard
      .writeText(
        webhook.secret,
      )

    setCopied(true)

    window.setTimeout(
      () =>
        setCopied(false),
      1200,
    )
  }

  return (
    <section className="webhook-secret-card">
      <div className="webhook-secret-card__warning">
        <AlertTriangle size={19} />

        <div>
          <strong>
            Save this signing secret now
          </strong>

          <p>
            HeyMail will never display
            this secret again. Store it
            securely before closing this
            message.
          </p>
        </div>

        <button
          aria-label="Dismiss secret"
          className="secret-dismiss"
          onClick={
            onDismiss
          }
          type="button"
        >
          <X size={16} />
        </button>
      </div>

      <div className="webhook-secret-value">
        <code>
          {webhook.secret}
        </code>

        <button
          className="button button--secondary button--inline"
          onClick={
            copy
          }
          type="button"
        >
          {copied
            ? (
                <Check size={14} />
              )
            : (
                <Clipboard size={14} />
              )}

          {copied
            ? 'Copied'
            : 'Copy secret'}
        </button>
      </div>

      <div className="webhook-secret-card__meta">
        <span>
          Webhook ID
        </span>

        <code>
          {webhook.webhookId}
        </code>
      </div>
    </section>
  )
}

function WebhookRow({
  webhook,
}: {
  webhook: WebhookEndpoint
}) {
  return (
    <article className="webhook-row">
      <div className="webhook-row__status">
        <span
          className={
            webhook.enabled
              ? 'webhook-status webhook-status--enabled'
              : 'webhook-status webhook-status--disabled'
          }
        >
          {webhook.enabled
            ? 'Enabled'
            : 'Disabled'}
        </span>
      </div>

      <div className="webhook-row__main">
        <strong title={webhook.url}>
          {webhook.url}
        </strong>

        <div className="webhook-row__meta">
          <code>
            {webhook.webhookId}
          </code>

          <span>
            Created
            {' '}
            {formatDateTime(
              webhook.createdAt,
            )}
          </span>
        </div>

        <div className="webhook-chips">
          {webhook.events.map(
            (event) => (
              <span
                className={
                  `webhook-chip webhook-chip--${event}`
                }
                key={event}
              >
                {event}
              </span>
            ),
          )}
        </div>
      </div>

      <div className="webhook-row__signature">
        <ShieldCheck size={15} />

        <span>
          HMAC-SHA256
        </span>
      </div>
    </article>
  )
}
