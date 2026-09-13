import {
  Activity,
  Braces,
  CheckCircle2,
  Globe2,
  KeyRound,
  Mail,
  Send,
  Webhook,
} from 'lucide-react'

const endpoints = [
  {
    method: 'POST',
    path: '/api/v1/send',
    description:
      'Submit an idempotent transactional message.',
    icon: Send,
  },
  {
    method: 'GET',
    path: '/api/v1/messages',
    description:
      'Query messages with cursor pagination and filters.',
    icon: Mail,
  },
  {
    method: 'GET',
    path: '/api/v1/messages/{id}',
    description:
      'Inspect lifecycle and delivery events.',
    icon: Activity,
  },
  {
    method: 'GET',
    path: '/api/v1/dashboard',
    description:
      'Retrieve aggregate delivery metrics.',
    icon: Braces,
  },
  {
    method: 'POST',
    path: '/api/v1/domains',
    description:
      'Register a sending domain.',
    icon: Globe2,
  },
  {
    method: 'POST',
    path: '/api/v1/senders',
    description:
      'Authorize an exact sender identity.',
    icon: CheckCircle2,
  },
  {
    method: 'GET / POST',
    path: '/api/v1/webhooks',
    description:
      'Manage signed delivery webhooks.',
    icon: Webhook,
  },
]

export function DocumentationPage() {
  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Developer
          </span>

          <h1>
            Documentation
          </h1>

          <p>
            Core HTTP API concepts and
            endpoint reference.
          </p>
        </div>
      </header>

      <section className="docs-hero">
        <div>
          <div className="docs-hero__icon">
            <KeyRound size={20} />
          </div>

          <span>
            API v1
          </span>

          <h2>
            Transactional email built
            around explicit delivery
            state.
          </h2>

          <p>
            Authenticate with HTTP Basic,
            use an Idempotency-Key on
            sends, and inspect downstream
            recipient delivery events
            independently from local
            submission status.
          </p>
        </div>
      </section>

      <div className="docs-concepts">
        <ConceptCard
          title="Idempotency"
          text="Every send requires an Idempotency-Key. Reusing the same key with the same payload safely replays the original request."
        />

        <ConceptCard
          title="Submission state"
          text="Message status tracks the local handoff lifecycle through queued, submitting, uncertain and submitted states."
        />

        <ConceptCard
          title="Delivery events"
          text="Delivered, tempfail and bounced are recipient-level immutable events, not global message statuses."
        />

        <ConceptCard
          title="Webhooks"
          text="Delivery webhooks are HTTPS-only, HMAC-SHA256 signed and retried with application-managed backoff."
        />
      </div>

      <section className="panel">
        <header className="panel__header">
          <div>
            <h2>
              Endpoint reference
            </h2>

            <p>
              Current HeyMail API v1
              surface.
            </p>
          </div>
        </header>

        <div className="endpoint-list">
          {endpoints.map(
            ({
              method,
              path,
              description,
              icon: Icon,
            }) => (
              <article
                className="endpoint-row"
                key={`${method}-${path}`}
              >
                <div className="endpoint-row__icon">
                  <Icon size={15} />
                </div>

                <span
                  className={
                    method.startsWith(
                      'POST',
                    )
                      ? 'http-method http-method--post'
                      : 'http-method'
                  }
                >
                  {method}
                </span>

                <code>
                  {path}
                </code>

                <p>
                  {description}
                </p>
              </article>
            ),
          )}
        </div>
      </section>
    </div>
  )
}

function ConceptCard({
  title,
  text,
}: {
  title: string
  text: string
}) {
  return (
    <article className="panel concept-card">
      <strong>
        {title}
      </strong>

      <p>
        {text}
      </p>
    </article>
  )
}
