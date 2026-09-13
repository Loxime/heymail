import {
  AlertTriangle,
  CheckCircle2,
  Mail,
  Send,
} from 'lucide-react'
import {
  useQuery,
} from '@tanstack/react-query'
import {
  Link,
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
  DashboardResponse,
  MessageListResponse,
} from '../../lib/api/types'
import {
  formatDateTime,
  formatPercent,
} from '../../lib/format/date'
import {
  ActivityChart,
} from './ActivityChart'

export function DashboardPage() {
  const dashboard =
    useQuery({
      queryKey: [
        'dashboard',
      ],

      queryFn: () =>
        apiGet<DashboardResponse>(
          '/api/v1/dashboard',
        ),
    })

  const messages =
    useQuery({
      queryKey: [
        'messages',
        'recent',
      ],

      queryFn: () =>
        apiGet<MessageListResponse>(
          '/api/v1/messages?limit=5',
        ),
    })

  if (dashboard.isLoading) {
    return (
      <DashboardSkeleton />
    )
  }

  if (
    dashboard.isError
    || !dashboard.data
  ) {
    return (
      <div className="state-card">
        <AlertTriangle size={24} />

        <div>
          <strong>
            Dashboard unavailable
          </strong>

          <p>
            {dashboard.error
              instanceof Error
              ? dashboard.error.message
              : 'Unable to load HeyMail metrics.'}
          </p>
        </div>

        <button
          className="button button--primary"
          onClick={() =>
            dashboard.refetch()
          }
          type="button"
        >
          Retry
        </button>
      </div>
    )
  }

  const data =
    dashboard.data

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Overview
          </span>

          <h1>
            Dashboard
          </h1>

          <p>
            Monitor transactional mail,
            delivery health and recent
            activity.
          </p>
        </div>

        <div className="period-pill">
          Last 30 days
        </div>
      </header>

      <section className="kpi-grid">
        <KpiCard
          detail={`${data.messages.submitted} currently submitted`}
          icon={Mail}
          label="Messages"
          value={
            data.messages.total
              .toLocaleString()
          }
        />

        <KpiCard
          detail={`${data.delivery.delivered} terminal deliveries`}
          icon={CheckCircle2}
          label="Delivery rate"
          tone="success"
          value={
            formatPercent(
              data.delivery.deliveryRate,
            )
          }
        />

        <KpiCard
          detail={`${data.delivery.bounced} bounced recipients`}
          icon={AlertTriangle}
          label="Bounce rate"
          tone={
            data.delivery.bounceRate
            > 0.05
              ? 'danger'
              : 'neutral'
          }
          value={
            formatPercent(
              data.delivery.bounceRate,
            )
          }
        />

        <KpiCard
          detail={`${data.delivery.tempfail} temporary failures`}
          icon={Send}
          label="Terminal outcomes"
          value={
            data.delivery.terminalOutcomes
              .toLocaleString()
          }
        />
      </section>

      <div className="dashboard-grid">
        <section className="panel panel--activity">
          <header className="panel__header">
            <div>
              <h2>
                Delivery activity
              </h2>

              <p>
                Submission and recipient
                events by UTC day.
              </p>
            </div>
          </header>

          <ActivityChart
            data={data.activity}
          />
        </section>

        <section className="panel">
          <header className="panel__header">
            <div>
              <h2>
                Message health
              </h2>

              <p>
                Current local submission
                states.
              </p>
            </div>
          </header>

          <div className="health-list">
            <HealthRow
              label="Submitted"
              total={data.messages.total}
              value={data.messages.submitted}
            />

            <HealthRow
              label="Queued"
              total={data.messages.total}
              value={data.messages.queued}
            />

            <HealthRow
              label="Submitting"
              total={data.messages.total}
              value={data.messages.submitting}
            />

            <HealthRow
              label="Uncertain"
              total={data.messages.total}
              value={
                data.messages.submissionUncertain
              }
              warning
            />
          </div>
        </section>
      </div>

      <section className="panel">
        <header className="panel__header panel__header--row">
          <div>
            <h2>
              Recent messages
            </h2>

            <p>
              Latest transactional
              submissions.
            </p>
          </div>

          <Link
            className="text-link"
            to="/messages"
          >
            View all
          </Link>
        </header>

        {messages.isLoading && (
          <div className="table-loading">
            Loading recent messages…
          </div>
        )}

        {messages.data && (
          <div className="table-scroll">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Message</th>
                  <th>Status</th>
                  <th>Created</th>
                  <th>Delivered</th>
                  <th>Bounced</th>
                </tr>
              </thead>

              <tbody>
                {messages.data.items.map(
                  (message) => (
                    <tr
                      key={
                        message.messageId
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
                            message.messageId
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
                          message.createdAt,
                        )}
                      </td>

                      <td>
                        {
                          message
                            .deliverySummary
                            .delivered
                        }
                      </td>

                      <td>
                        {
                          message
                            .deliverySummary
                            .bounced
                        }
                      </td>
                    </tr>
                  ),
                )}
              </tbody>
            </table>
          </div>
        )}

        {messages.isError && (
          <div className="table-loading">
            Recent messages could not be
            loaded.
          </div>
        )}
      </section>
    </div>
  )
}

interface HealthRowProps {
  label: string
  value: number
  total: number
  warning?: boolean
}

function HealthRow({
  label,
  value,
  total,
  warning = false,
}: HealthRowProps) {
  const percentage =
    total === 0
      ? 0
      : value / total * 100

  return (
    <div className="health-row">
      <div className="health-row__copy">
        <span>{label}</span>
        <strong>{value}</strong>
      </div>

      <div className="health-progress">
        <span
          className={
            warning
              ? 'health-progress__bar health-progress__bar--warning'
              : 'health-progress__bar'
          }
          style={{
            width:
              `${Math.min(
                100,
                percentage,
              )}%`,
          }}
        />
      </div>
    </div>
  )
}

function DashboardSkeleton() {
  return (
    <div className="page">
      <div className="skeleton skeleton--heading" />

      <div className="kpi-grid">
        {Array.from({
          length: 4,
        }).map((_, index) => (
          <div
            className="skeleton skeleton--card"
            key={index}
          />
        ))}
      </div>

      <div className="skeleton skeleton--panel" />
    </div>
  )
}
