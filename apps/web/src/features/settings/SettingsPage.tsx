import type {
  ReactNode,
} from 'react'

import {
  BadgeCheck,
  Globe2,
  Database,
  LockKeyhole,
  Network,
  ShieldCheck,
} from 'lucide-react'

export function SettingsPage() {
  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Settings
          </span>

          <h1>
            Console settings
          </h1>

          <p>
            Runtime and security posture
            for this HeyMail console.
          </p>
        </div>
      </header>

      <div className="settings-grid">
        <SettingsCard
          icon={Globe2}
          title="Frontend"
          value="React console"
          description="Browser UI with same-origin API access."
        />

        <SettingsCard
          icon={Network}
          title="API transport"
          value="Same-origin proxy"
          description="API credentials remain outside browser JavaScript."
        />

        <SettingsCard
          icon={LockKeyhole}
          title="Credentials"
          value="Server-managed"
          description="API secrets are read from dedicated server-side files."
        />

        <SettingsCard
          icon={Database}
          title="Message payload"
          value="Encrypted at rest"
          description="Sensitive email content is not stored in lifecycle event tables."
        />
      </div>

      <section className="panel security-posture">
        <header className="panel__header">
          <div>
            <h2>
              Security posture
            </h2>

            <p>
              Product invariants enforced
              by the current architecture.
            </p>
          </div>
        </header>

        <div className="security-checklist">
          <SecurityCheck>
            No API secret embedded in the
            frontend bundle
          </SecurityCheck>

          <SecurityCheck>
            DKIM private keys remain
            outside browser-facing APIs
          </SecurityCheck>

          <SecurityCheck>
            Webhook secrets are displayed
            only once at creation
          </SecurityCheck>

          <SecurityCheck>
            Submission uncertainty is
            preserved instead of blindly
            retrying SMTP handoff
          </SecurityCheck>

          <SecurityCheck>
            Delivery diagnostics expose
            recipient hashes rather than
            plaintext addresses
          </SecurityCheck>
        </div>
      </section>

      <section className="settings-note">
        <ShieldCheck size={18} />

        <div>
          <strong>
            No mutable product settings
            are exposed yet.
          </strong>

          <p>
            This page intentionally does
            not provide fake controls.
            Settings will become editable
            only when corresponding
            backend configuration APIs
            exist.
          </p>
        </div>
      </section>
    </div>
  )
}

function SettingsCard({
  icon: Icon,
  title,
  value,
  description,
}: {
  icon: typeof BadgeCheck
  title: string
  value: string
  description: string
}) {
  return (
    <article className="panel settings-card">
      <div className="settings-card__icon">
        <Icon size={18} />
      </div>

      <span>
        {title}
      </span>

      <strong>
        {value}
      </strong>

      <p>
        {description}
      </p>
    </article>
  )
}

function SecurityCheck({
  children,
}: {
  children: ReactNode
}) {
  return (
    <div className="security-check">
      <BadgeCheck size={16} />

      <span>
        {children}
      </span>
    </div>
  )
}
