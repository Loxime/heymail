import {
  Check,
  Clipboard,
  KeyRound,
  LockKeyhole,
  ServerCog,
  ShieldCheck,
  Terminal,
} from 'lucide-react'
import {
  useState,
} from 'react'

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

export function CredentialsPage() {
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
            Authenticate server-to-server
            requests without exposing
            secrets to browser code.
          </p>
        </div>
      </header>

      <div className="developer-grid">
        <section className="panel credential-overview">
          <header className="panel__header">
            <div>
              <h2>
                Authentication
              </h2>

              <p>
                HTTP Basic authentication
                using a HeyMail API key
                and secret.
              </p>
            </div>
          </header>

          <div className="credential-overview__body">
            <SecurityRow
              icon={KeyRound}
              label="API key"
              value="hm_••••••••••••••••••••••••••••••••"
            />

            <SecurityRow
              icon={LockKeyhole}
              label="API secret"
              value="Hidden from browser clients"
            />

            <SecurityRow
              icon={ServerCog}
              label="Provisioning"
              value="Server-managed secret files"
            />

            <SecurityRow
              icon={ShieldCheck}
              label="Browser policy"
              value="Credentials never enter the frontend bundle"
            />
          </div>
        </section>

        <section className="panel credential-security">
          <div className="credential-security__icon">
            <ShieldCheck size={22} />
          </div>

          <strong>
            Secret isolation is enforced
          </strong>

          <p>
            HeyMail's developer console
            does not fetch, reveal or
            persist API secrets. Browser
            requests use the local
            same-origin proxy during
            development.
          </p>
        </section>
      </div>

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

      {copied
        ? 'Copied'
        : 'Copy'}
    </button>
  )
}
