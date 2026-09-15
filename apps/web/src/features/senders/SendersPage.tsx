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
  useEffect,
  useMemo,
  useState,
} from 'react'

import {
  apiGet,
  apiPost,
} from '../../lib/api/client'
import type {
  SenderIdentityCreateResponse,
  SenderIdentityListResponse,
  SendingDomainListResponse,
} from '../../lib/api/types'
import {
  formatDateTime,
} from '../../lib/format/date'

export function SendersPage() {
  const queryClient = useQueryClient()

  const [localPart, setLocalPart] = useState('')
  const [domain, setDomain] = useState('')

  const senders = useQuery({
    queryKey: ['senders'],
    queryFn: () =>
      apiGet<SenderIdentityListResponse>(
        '/api/v1/senders',
      ),
  })

  const domains = useQuery({
    queryKey: ['domains'],
    queryFn: () =>
      apiGet<SendingDomainListResponse>(
        '/api/v1/domains',
      ),
  })

  const readyDomains = useMemo(
    () =>
      domains.data?.items.filter(
        (item) =>
          item.status === 'verified'
          && item.dkim.ready,
      ) ?? [],
    [domains.data],
  )

  useEffect(
    () => {
      if (
        domain === ''
        && readyDomains.length > 0
      ) {
        const preferred =
          readyDomains.find(
            (item) =>
              item.domain
              === 'heymail.falchero.fr',
          )
          ?? readyDomains[0]

        setDomain(preferred.domain)
      }
    },
    [domain, readyDomains],
  )

  const senderEmail =
    localPart.trim() !== ''
    && domain !== ''
      ? `${localPart.trim()}@${domain}`
      : ''

  const createSender = useMutation({
    mutationFn: () =>
      apiPost<SenderIdentityCreateResponse>(
        '/api/v1/senders',
        {
          email: senderEmail,
        },
      ),
    onSuccess: async () => {
      setLocalPart('')
      await queryClient.invalidateQueries({
        queryKey: ['senders'],
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

          <h1>Expéditeurs</h1>

          <p>
            Créez des adresses From sur vos
            domaines vérifiés et prêts DKIM.
          </p>
        </div>

        <button
          className="button button--secondary"
          onClick={() => {
            senders.refetch()
            domains.refetch()
          }}
          type="button"
        >
          <RefreshCw size={14} />
          Actualiser
        </button>
      </header>

      <section className="panel create-resource">
        <div className="create-resource__copy">
          <div className="resource-icon">
            <UserRoundCheck size={19} />
          </div>

          <div>
            <strong>
              Ajouter une adresse expéditeur
            </strong>

            <p>
              Saisissez seulement la partie avant
              @ puis choisissez un domaine prêt.
            </p>
          </div>
        </div>

        <form
          className="create-resource__form sender-address-builder"
          onSubmit={(event) => {
            event.preventDefault()

            if (senderEmail !== '') {
              createSender.mutate()
            }
          }}
        >
          <div className="sender-address-builder__address">
            <input
              aria-label="Préfixe de l'adresse expéditeur"
              autoComplete="off"
              onChange={(event) =>
                setLocalPart(
                  event.target.value.replace('@', ''),
                )
              }
              placeholder="support"
              value={localPart}
            />

            <span>@</span>

            <select
              aria-label="Domaine expéditeur"
              disabled={readyDomains.length === 0}
              onChange={(event) =>
                setDomain(event.target.value)
              }
              value={domain}
            >
              {readyDomains.length === 0 && (
                <option value="">
                  Aucun domaine prêt
                </option>
              )}

              {readyDomains.map((item) => (
                <option
                  key={item.id}
                  value={item.domain}
                >
                  {item.domain}
                </option>
              ))}
            </select>
          </div>

          <button
            className="button button--primary button--inline"
            disabled={
              createSender.isPending
              || senderEmail === ''
            }
            type="submit"
          >
            <Plus size={14} />
            Ajouter
          </button>
        </form>
      </section>

      {senderEmail !== '' && (
        <div className="sender-preview">
          Adresse créée : <strong>{senderEmail}</strong>
        </div>
      )}

      {createSender.error instanceof Error && (
        <div className="inline-error">
          {createSender.error.message}
        </div>
      )}

      {senders.isError && (
        <div className="inline-error">
          {senders.error instanceof Error
            ? senders.error.message
            : 'Unable to load senders.'}
        </div>
      )}

      <section className="panel">
        <header className="panel__header panel__header--row">
          <div>
            <h2>Expéditeurs autorisés</h2>
            <p>
              Identités From acceptées par l'API.
            </p>
          </div>
        </header>

        {senders.isLoading && (
          <div className="message-table-skeleton">
            {Array.from({ length: 5 }).map((_, index) => (
              <div
                className="skeleton message-table-skeleton__row"
                key={index}
              />
            ))}
          </div>
        )}

        {senders.data?.items.length === 0 && (
          <div className="empty-state">
            <div className="empty-state__icon">
              <Mail size={22} />
            </div>

            <strong>Aucun expéditeur</strong>
            <span>
              Vérifiez un domaine puis créez votre
              première adresse expéditeur.
            </span>
          </div>
        )}

        {senders.data
          && senders.data.items.length > 0 && (
          <div className="table-scroll">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Expéditeur</th>
                  <th>Domaine</th>
                  <th>Autorisation</th>
                  <th>Créé</th>
                </tr>
              </thead>

              <tbody>
                {senders.data.items.map((sender) => (
                  <tr key={sender.id}>
                    <td>
                      <div className="sender-cell">
                        <div className="sender-avatar">
                          {sender.email
                            .charAt(0)
                            .toUpperCase()}
                        </div>

                        <strong>{sender.email}</strong>
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
                              Autorisé
                            </span>
                          )
                        : (
                            <span className="authorization authorization--blocked">
                              <ShieldAlert size={13} />
                              Bloqué
                            </span>
                          )}
                    </td>

                    <td className="table-muted">
                      {formatDateTime(sender.createdAt)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  )
}
