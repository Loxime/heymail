import {
  AlertTriangle,
  ArrowLeft,
  Check,
  CircleDot,
  Clock3,
  MailCheck,
  RotateCcw,
  X,
} from 'lucide-react'
import {
  useQuery,
} from '@tanstack/react-query'
import {
  Link,
  useParams,
} from 'react-router-dom'

import {
  KpiCard,
} from '../../components/data-display/KpiCard'
import {
  StatusBadge,
} from '../../components/data-display/StatusBadge'
import {
  apiGet,
} from '../../lib/api/client'
import type {
  MessageDetailResponse,
  MessageEvent,
} from '../../lib/api/types'
import {
  formatDateTime,
} from '../../lib/format/date'

export function MessageDetailPage() {
  const {
    id,
  } = useParams()

  const messageId =
    Number(id)

  const query =
    useQuery({
      queryKey: [
        'message',
        messageId,
      ],

      enabled:
        Number.isInteger(
          messageId,
        )
        && messageId > 0,

      queryFn: () =>
        apiGet<MessageDetailResponse>(
          `/api/v1/messages/${messageId}`,
        ),
    })

  if (query.isLoading) {
    return (
      <div className="page">
        <div className="skeleton skeleton--heading" />
        <div className="skeleton skeleton--panel" />
      </div>
    )
  }

  if (
    query.isError
    || !query.data
  ) {
    return (
      <div className="page">
        <Link
          className="back-link"
          to="/messages"
        >
          <ArrowLeft size={15} />
          Messages
        </Link>

        <div className="state-card">
          <AlertTriangle size={22} />

          <div>
            <strong>
              Message unavailable
            </strong>

            <p>
              {query.error
                instanceof Error
                ? query
                    .error
                    .message
                : 'Unable to load the message.'}
            </p>
          </div>
        </div>
      </div>
    )
  }

  const message =
    query.data

  return (
    <div className="page">
      <Link
        className="back-link"
        to="/messages"
      >
        <ArrowLeft size={15} />
        Messages
      </Link>

      <header className="page-heading message-detail-heading">
        <div>
          <span className="eyebrow">
            Transactional message
          </span>

          <div className="message-title-row">
            <h1>
              Message #
              {message.messageId}
            </h1>

            <StatusBadge
              status={
                message.status
              }
            />
          </div>

          <p>
            Created
            {' '}
            {formatDateTime(
              message.createdAt,
            )}
          </p>
        </div>
      </header>

      <section className="kpi-grid kpi-grid--three">
        <KpiCard
          detail="Recipient delivery events"
          icon={MailCheck}
          label="Delivered"
          tone="success"
          value={
            message
              .deliverySummary
              .delivered
              .toLocaleString()
          }
        />

        <KpiCard
          detail="Temporary SMTP failures"
          icon={RotateCcw}
          label="Tempfail"
          tone="warning"
          value={
            message
              .deliverySummary
              .tempfail
              .toLocaleString()
          }
        />

        <KpiCard
          detail="Permanent recipient failures"
          icon={X}
          label="Bounced"
          tone="danger"
          value={
            message
              .deliverySummary
              .bounced
              .toLocaleString()
          }
        />
      </section>

      <div className="message-detail-grid">
        <section className="panel">
          <header className="panel__header">
            <div>
              <h2>
                Event timeline
              </h2>

              <p>
                Application lifecycle and
                downstream SMTP feedback.
              </p>
            </div>
          </header>

          <div className="timeline">
            {message.events.map(
              (
                event,
                index,
              ) => (
                <TimelineEvent
                  event={event}
                  key={
                    `${event.occurredAt}-${event.type}-${index}`
                  }
                  last={
                    index
                    === message
                      .events
                      .length
                      - 1
                  }
                />
              ),
            )}
          </div>
        </section>

        <aside className="panel message-metadata">
          <header className="panel__header">
            <div>
              <h2>
                Submission
              </h2>

              <p>
                Local processing state.
              </p>
            </div>
          </header>

          <dl className="metadata-list">
            <MetadataRow
              label="Created"
              value={
                message.createdAt
              }
            />

            <MetadataRow
              label="Ready"
              value={
                message
                  .readyForSubmissionAt
              }
            />

            <MetadataRow
              label="Submitting"
              value={
                message.submittingAt
              }
            />

            <MetadataRow
              label="Uncertain"
              value={
                message
                  .submissionUncertainAt
              }
            />

            <MetadataRow
              label="Submitted"
              value={
                message.submittedAt
              }
            />
          </dl>
        </aside>
      </div>
    </div>
  )
}

function MetadataRow({
  label,
  value,
}: {
  label: string
  value: string | null
}) {
  return (
    <div className="metadata-row">
      <dt>
        {label}
      </dt>

      <dd>
        {value
          ? formatDateTime(
              value,
            )
          : '—'}
      </dd>
    </div>
  )
}

function TimelineEvent({
  event,
  last,
}: {
  event: MessageEvent
  last: boolean
}) {
  const delivery =
    event.recipientHash
    !== null

  return (
    <article className="timeline-event">
      <div className="timeline-event__rail">
        <div
          className={
            `timeline-event__icon timeline-event__icon--${event.type}`
          }
        >
          <EventIcon
            type={
              event.type
            }
          />
        </div>

        {!last && (
          <span className="timeline-event__line" />
        )}
      </div>

      <div className="timeline-event__body">
        <div className="timeline-event__heading">
          <strong>
            {eventLabel(
              event.type,
            )}
          </strong>

          <time>
            {formatDateTime(
              event.occurredAt,
            )}
          </time>
        </div>

        {delivery && (
          <div className="delivery-event-card">
            <div className="delivery-event-card__recipient">
              <span>
                Recipient
              </span>

              <code>
                {shortHash(
                  event
                    .recipientHash,
                )}
              </code>
            </div>

            {event.smtpStatus && (
              <span className="smtp-status">
                SMTP
                {' '}
                {event.smtpStatus}
              </span>
            )}

            {event.detail && (
              <p>
                {event.detail}
              </p>
            )}
          </div>
        )}
      </div>
    </article>
  )
}

function EventIcon({
  type,
}: {
  type: string
}) {
  switch (type) {
    case 'delivered':
      return (
        <Check size={15} />
      )

    case 'bounced':
      return (
        <X size={15} />
      )

    case 'tempfail':
      return (
        <RotateCcw size={14} />
      )

    case 'submission_uncertain':
      return (
        <AlertTriangle size={14} />
      )

    case 'submitted':
      return (
        <MailCheck size={14} />
      )

    case 'submitting':
      return (
        <Clock3 size={14} />
      )

    default:
      return (
        <CircleDot size={13} />
      )
  }
}

function eventLabel(
  type: string,
): string {
  return type
    .split('_')
    .map(
      (word) =>
        word.charAt(0).toUpperCase()
        + word.slice(1),
    )
    .join(' ')
}

function shortHash(
  hash: string | null,
): string {
  if (!hash) {
    return '—'
  }

  return `${hash.slice(
    0,
    10,
  )}…${hash.slice(-6)}`
}
