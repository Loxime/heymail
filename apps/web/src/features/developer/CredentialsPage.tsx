import {
  Check,
  Clipboard,
  KeyRound,
  LockKeyhole,
  RefreshCw,
  ShieldCheck,
  Trash2,
} from 'lucide-react'
import {
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
  ConsoleApiCredential,
  ConsoleApiCredentialListResponse,
  ConsoleApiCredentialSecretResponse,
} from '../../lib/api/types'

const curlExample = `export HEYMAIL_API_KEY='hm_...'
export HEYMAIL_API_SECRET='...'

curl \\
  --user "$HEYMAIL_API_KEY:$HEYMAIL_API_SECRET" \\
  --header 'Content-Type: application/json' \\
  --header 'Idempotency-Key: example-001' \\
  --data '{
    "from": {
      "email": "hello@example.com"
    },
    "to": [
      {
        "email": "recipient@example.net"
      }
    ],
    "subject": "Hello from HeyMail",
    "text": "Transactional email works."
  }' \\
  https://api.example.com/api/v1/send`

interface RevealedSecret {
  apiKey: string
  secret: string
  label: string
}

export function CredentialsPage() {
  const queryClient = useQueryClient()

  const credentials = useQuery({
    queryKey: [
      'console-api-credentials',
    ],
    queryFn: () =>
      apiGet<ConsoleApiCredentialListResponse>(
        '/console/api-credentials',
      ),
  })

  const [label, setLabel] = useState('')
  const [revealed, setRevealed] =
    useState<RevealedSecret | null>(null)
  const [pending, setPending] =
    useState<string | null>(null)
  const [error, setError] =
    useState<string | null>(null)

  const refresh = async () => {
    await queryClient.invalidateQueries({
      queryKey: [
        'console-api-credentials',
      ],
    })
  }

  const createCredential = async () => {
    setPending('create')
    setError(null)

    try {
      const response =
        await apiPost<ConsoleApiCredentialSecretResponse>(
          '/console/api-credentials',
          {
            label: label.trim(),
          },
        )

      setRevealed({
        apiKey: response.credential.apiKey,
        secret: response.secret,
        label: response.credential.label,
      })
      setLabel('')
      await refresh()
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to create credential.',
      )
    } finally {
      setPending(null)
    }
  }

  const rotateCredential = async (
    credential: ConsoleApiCredential,
  ) => {
    setPending(
      `rotate:${credential.id}`,
    )
    setError(null)

    try {
      const response =
        await apiPost<ConsoleApiCredentialSecretResponse>(
          `/console/api-credentials/${credential.id}/rotate`,
        )

      setRevealed({
        apiKey: response.credential.apiKey,
        secret: response.secret,
        label: response.credential.label,
      })
      await refresh()
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to rotate credential.',
      )
    } finally {
      setPending(null)
    }
  }

  const revokeCredential = async (
    credential: ConsoleApiCredential,
  ) => {
    setPending(
      `revoke:${credential.id}`,
    )
    setError(null)

    try {
      await apiDelete<void>(
        `/console/api-credentials/${credential.id}`,
      )

      if (
        revealed?.apiKey
        === credential.apiKey
      ) {
        setRevealed(null)
      }

      await refresh()
    } catch (caught) {
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to revoke credential.',
      )
    } finally {
      setPending(null)
    }
  }

  const items =
    credentials.data?.items
    ?? []

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Developer
          </span>

          <h1>
            API credentials
          </h1>

          <p>
            Create, rotate and revoke
            workspace-scoped server credentials.
          </p>
        </div>
      </header>

      <div className="developer-grid">
        <section className="panel credential-overview">
          <header className="panel__header">
            <div>
              <h2>
                Workspace authentication
              </h2>

              <p>
                HTTP Basic authentication
                using an API key and secret.
              </p>
            </div>
          </header>

          <div className="credential-overview__body">
            <SecurityRow
              icon={KeyRound}
              label="API keys"
              value="Multiple keys per workspace"
            />

            <SecurityRow
              icon={LockKeyhole}
              label="API secrets"
              value="Stored as one-way hashes"
            />

            <SecurityRow
              icon={RefreshCw}
              label="Rotation"
              value="Old secret invalidated immediately"
            />

            <SecurityRow
              icon={ShieldCheck}
              label="Browser policy"
              value="Secret returned only on create or rotate"
            />
          </div>
        </section>

        <section className="panel credential-security">
          <div className="credential-security__icon">
            <ShieldCheck size={22} />
          </div>

          <strong>
            Secret visibility is one-time
          </strong>

          <p>
            Copy a new secret immediately.
            HeyMail stores only its hash and
            cannot reveal it again after this
            response leaves the page.
          </p>
        </section>
      </div>

      <section className="panel profile-panel">
        <header className="panel__header">
          <div>
            <h2>
              Create credential
            </h2>

            <p>
              Give each application or
              environment its own key.
            </p>
          </div>
        </header>

        <div className="profile-panel__body">
          <div className="favorite-form">
            <input
              maxLength={100}
              onChange={(event) =>
                setLabel(event.target.value)
              }
              placeholder="Production API"
              value={label}
            />

            <div />

            <button
              className="button button--primary"
              disabled={
                pending !== null
                || label.trim() === ''
              }
              onClick={() => void createCredential()}
              type="button"
            >
              <KeyRound size={14} />
              Create credential
            </button>
          </div>

          {error && (
            <div className="inline-error">
              {error}
            </div>
          )}
        </div>
      </section>

      {revealed && (
        <section className="panel code-panel profile-panel">
          <header className="panel__header panel__header--row">
            <div>
              <h2>
                Copy this secret now
              </h2>

              <p>
                {revealed.label} — it will
                not be returned by HeyMail again.
              </p>
            </div>

            <button
              className="button button--secondary"
              onClick={() => setRevealed(null)}
              type="button"
            >
              Dismiss
            </button>
          </header>

          <pre>
            <code>
              {`HEYMAIL_API_KEY=${revealed.apiKey}\nHEYMAIL_API_SECRET=${revealed.secret}`}
            </code>
          </pre>

          <div className="profile-panel__body">
            <CopyButton
              value={
                `HEYMAIL_API_KEY=${revealed.apiKey}\n`
                + `HEYMAIL_API_SECRET=${revealed.secret}`
              }
            />
          </div>
        </section>
      )}

      <section className="panel profile-panel">
        <header className="panel__header">
          <div>
            <h2>
              Credentials
            </h2>

            <p>
              API keys remain visible for
              identification. Secrets do not.
            </p>
          </div>
        </header>

        <div className="profile-panel__body">
          {credentials.isLoading && (
            <span className="table-muted">
              Loading credentials…
            </span>
          )}

          {!credentials.isLoading
            && items.length === 0 && (
              <span className="table-muted">
                No workspace API credentials yet.
              </span>
            )}

          <div className="favorite-list">
            {items.map((credential) => {
              const revoked =
                credential.revokedAt !== null

              return (
                <div
                  className="favorite-row"
                  key={credential.id}
                >
                  <div>
                    <strong>
                      {credential.label}
                    </strong>

                    <span>
                      {credential.apiKey}
                    </span>

                    <span>
                      Fingerprint {credential.fingerprint.slice(0, 16)}…
                      {' · '}
                      Last used {
                        credential.lastUsedAt
                          ? formatDate(credential.lastUsedAt)
                          : 'never'
                      }
                      {' · '}
                      {revoked
                        ? `Revoked ${formatDate(credential.revokedAt!)}`
                        : 'Active'}
                    </span>
                  </div>

                  <div className="button-group">
                    <button
                      className="button button--secondary"
                      disabled={
                        pending !== null
                        || revoked
                      }
                      onClick={() =>
                        void rotateCredential(
                          credential,
                        )
                      }
                      type="button"
                    >
                      <RefreshCw size={13} />
                      Rotate
                    </button>

                    <button
                      className="button button--danger"
                      disabled={
                        pending !== null
                        || revoked
                      }
                      onClick={() =>
                        void revokeCredential(
                          credential,
                        )
                      }
                      type="button"
                    >
                      <Trash2 size={13} />
                      Revoke
                    </button>
                  </div>
                </div>
              )
            })}
          </div>
        </div>
      </section>

      <section className="panel code-panel">
        <header className="panel__header panel__header--row">
          <div>
            <h2>
              Server-side example
            </h2>

            <p>
              Keep credentials in your
              application's secret store.
            </p>
          </div>

          <CopyButton
            value={curlExample}
          />
        </header>

        <pre>
          <code>
            {curlExample}
          </code>
        </pre>
      </section>
    </div>
  )
}

function SecurityRow({
  icon: Icon,
  label,
  value,
}: {
  icon: typeof KeyRound
  label: string
  value: string
}) {
  return (
    <div className="security-row">
      <div className="security-row__icon">
        <Icon size={15} />
      </div>

      <div>
        <span>
          {label}
        </span>

        <strong>
          {value}
        </strong>
      </div>
    </div>
  )
}

function CopyButton({
  value,
}: {
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
    <button
      className="button button--secondary"
      onClick={() => void copy()}
      type="button"
    >
      {copied
        ? (
            <Check size={13} />
          )
        : (
            <Clipboard size={13} />
          )}

      {copied
        ? 'Copied'
        : 'Copy'}
    </button>
  )
}

function formatDate(
  value: string,
): string {
  return new Intl.DateTimeFormat(
    undefined,
    {
      dateStyle: 'medium',
      timeStyle: 'short',
    },
  ).format(
    new Date(value),
  )
}
