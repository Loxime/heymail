import {
  Check,
  Clipboard,
  Globe2,
  KeyRound,
  Plus,
  RefreshCw,
  ShieldCheck,
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
  DomainDkimProvisionResponse,
  DomainVerificationResponse,
  SendingDomain,
  SendingDomainCreateResponse,
  SendingDomainListResponse,
} from '../../lib/api/types'
import {
  formatDateTime,
} from '../../lib/format/date'

export function DomainsPage() {
  const queryClient =
    useQueryClient()

  const [
    domain,
    setDomain,
  ] = useState('')

  const domains =
    useQuery({
      queryKey: [
        'domains',
      ],

      queryFn: () =>
        apiGet<SendingDomainListResponse>(
          '/api/v1/domains',
        ),

      refetchInterval: (query) => {
        const items =
          query
            .state
            .data
            ?.items

        if (!items) {
          return false
        }

        return items.some(
          (item) =>
            item.status === 'pending'
            || (
              item.status === 'verified'
              && !item.dkim.ready
            ),
        )
          ? 3000
          : false
      },
    })

  const createDomain =
    useMutation({
      mutationFn: (
        value: string,
      ) =>
        apiPost<SendingDomainCreateResponse>(
          '/api/v1/domains',
          {
            domain: value,
          },
        ),

      onSuccess: async () => {
        setDomain('')

        await queryClient
          .invalidateQueries({
            queryKey: [
              'domains',
            ],
          })
      },
    })

  const verifyDomain =
    useMutation({
      mutationFn: (
        id: number,
      ) =>
        apiPost<DomainVerificationResponse>(
          `/api/v1/domains/${id}/verify`,
        ),

      onSuccess: async () => {
        await queryClient
          .invalidateQueries({
            queryKey: [
              'domains',
            ],
          })
      },
    })

  const provisionDkim =
    useMutation({
      mutationFn: (
        id: number,
      ) =>
        apiPost<DomainDkimProvisionResponse>(
          `/api/v1/domains/${id}/dkim/provision`,
        ),

      onSuccess: async () => {
        await queryClient
          .invalidateQueries({
            queryKey: [
              'domains',
            ],
          })
      },
    })

  const mutationError =
    createDomain.error
    ?? verifyDomain.error
    ?? provisionDkim.error

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Configuration
          </span>

          <h1>
            Domains
          </h1>

          <p>
            Verify sending domains and
            provision isolated DKIM keys.
          </p>
        </div>

        <button
          className="button button--secondary"
          onClick={() =>
            domains.refetch()
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
            <Globe2 size={19} />
          </div>

          <div>
            <strong>
              Add sending domain
            </strong>

            <p>
              HeyMail generates a unique
              DNS ownership record.
            </p>
          </div>
        </div>

        <form
          className="create-resource__form"
          onSubmit={(event) => {
            event.preventDefault()

            const value =
              domain.trim()

            if (value === '') {
              return
            }

            createDomain.mutate(
              value,
            )
          }}
        >
          <input
            aria-label="Domain"
            autoComplete="off"
            onChange={(event) =>
              setDomain(
                event.target.value,
              )
            }
            placeholder="example.com"
            spellCheck={false}
            value={domain}
          />

          <button
            className="button button--primary button--inline"
            disabled={
              createDomain.isPending
              || domain.trim() === ''
            }
            type="submit"
          >
            <Plus size={14} />
            Add domain
          </button>
        </form>
      </section>

      {mutationError
        instanceof Error && (
          <div className="inline-error">
            {mutationError.message}
          </div>
        )}

      {domains.isError && (
        <div className="inline-error">
          {domains.error
            instanceof Error
            ? domains.error.message
            : 'Unable to load domains.'}
        </div>
      )}

      {domains.isLoading && (
        <div className="resource-grid">
          {Array.from({
            length: 2,
          }).map((_, index) => (
            <div
              className="skeleton resource-card-skeleton"
              key={index}
            />
          ))}
        </div>
      )}

      {domains.data?.items.length
        === 0 && (
          <div className="panel empty-state">
            <div className="empty-state__icon">
              <Globe2 size={22} />
            </div>

            <strong>
              No sending domains
            </strong>

            <span>
              Add your first domain to
              begin DNS verification.
            </span>
          </div>
        )}

      <div className="resource-grid">
        {domains.data?.items.map(
          (item) => (
            <DomainCard
              domain={item}
              key={item.id}
              provisioning={
                provisionDkim.isPending
              }
              verifying={
                verifyDomain.isPending
              }
              onProvision={() =>
                provisionDkim.mutate(
                  item.id,
                )
              }
              onVerify={() =>
                verifyDomain.mutate(
                  item.id,
                )
              }
            />
          ),
        )}
      </div>
    </div>
  )
}

function DomainCard({
  domain,
  verifying,
  provisioning,
  onVerify,
  onProvision,
}: {
  domain: SendingDomain
  verifying: boolean
  provisioning: boolean
  onVerify: () => void
  onProvision: () => void
}) {
  return (
    <article className="panel resource-card">
      <header className="resource-card__header">
        <div className="resource-card__title">
          <div className="resource-icon">
            <Globe2 size={17} />
          </div>

          <div>
            <strong>
              {domain.domain}
            </strong>

            <span>
              Added
              {' '}
              {formatDateTime(
                domain.createdAt,
              )}
            </span>
          </div>
        </div>

        <span
          className={
            `domain-status domain-status--${domain.status}`
          }
        >
          {domain.status}
        </span>
      </header>

      <div className="resource-card__section">
        <div className="resource-card__section-heading">
          <div>
            <ShieldCheck size={15} />

            <strong>
              Domain verification
            </strong>
          </div>

          {domain.status
            === 'verified' && (
              <span className="ready-label">
                <Check size={12} />
                Verified
              </span>
            )}
        </div>

        <DnsRecord
          name={
            domain
              .verification
              .name
          }
          value={
            domain
              .verification
              .value
          }
        />

        {domain.status
          === 'pending' && (
            <button
              className="button button--secondary"
              disabled={verifying}
              onClick={
                onVerify
              }
              type="button"
            >
              <RefreshCw size={13} />
              Check DNS
            </button>
          )}

        {domain.verificationCheckedAt && (
          <span className="resource-card__timestamp">
            Last checked
            {' '}
            {formatDateTime(
              domain
                .verificationCheckedAt,
            )}
          </span>
        )}
      </div>

      <div className="resource-card__section">
        <div className="resource-card__section-heading">
          <div>
            <KeyRound size={15} />

            <strong>
              DKIM signing
            </strong>
          </div>

          {domain.dkim.ready && (
            <span className="ready-label">
              <Check size={12} />
              Ready
            </span>
          )}
        </div>

        {!domain.dkim.ready
          && domain.status
            !== 'verified' && (
            <p className="resource-hint">
              Verify this domain before
              provisioning DKIM.
            </p>
          )}

        {!domain.dkim.ready
          && domain.status
            === 'verified' && (
            <button
              className="button button--secondary"
              disabled={
                provisioning
              }
              onClick={
                onProvision
              }
              type="button"
            >
              <KeyRound size={13} />
              Provision DKIM
            </button>
          )}

        {domain.dkim.ready
          && domain.dkim.name
          && domain.dkim.value && (
            <>
              <DnsRecord
                name={
                  domain.dkim.name
                }
                value={
                  domain.dkim.value
                }
              />

              <span className="resource-card__timestamp">
                Selector
                {' '}
                <code>
                  {domain.dkim.selector}
                </code>
              </span>
            </>
          )}
      </div>
    </article>
  )
}

function DnsRecord({
  name,
  value,
}: {
  name: string
  value: string
}) {
  return (
    <div className="dns-record">
      <DnsValue
        label="TXT name"
        value={name}
      />

      <DnsValue
        label="TXT value"
        value={value}
      />
    </div>
  )
}

function DnsValue({
  label,
  value,
}: {
  label: string
  value: string
}) {
  const [
    copied,
    setCopied,
  ] = useState(false)

  const copy = async () => {
    await navigator.clipboard
      .writeText(
        value,
      )

    setCopied(true)

    window.setTimeout(
      () =>
        setCopied(false),
      1200,
    )
  }

  return (
    <div className="dns-value">
      <span>
        {label}
      </span>

      <div>
        <code title={value}>
          {value}
        </code>

        <button
          aria-label={`Copy ${label}`}
          className="copy-button"
          onClick={
            copy
          }
          type="button"
        >
          {copied
            ? (
                <Check size={13} />
              )
            : (
                <Clipboard size={13} />
              )}
        </button>
      </div>
    </div>
  )
}
