import {
  Clock3,
  Pause,
  Play,
  Plus,
  Trash2,
  Workflow,
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
  apiDelete,
  apiGet,
  apiPost,
} from '../../lib/api/client'
import type {
  ConsoleAutomation,
  ConsoleAutomationListResponse,
  ConsoleAutomationTriggerType,
  ConsoleEmailTemplateListResponse,
  SenderIdentityListResponse,
} from '../../lib/api/types'

function formatDelay(
  seconds: number,
): string {
  if (seconds === 0) {
    return 'Immediately'
  }

  if (seconds % 86400 === 0) {
    const days = seconds / 86400
    return `${days} day${days === 1 ? '' : 's'}`
  }

  if (seconds % 3600 === 0) {
    const hours = seconds / 3600
    return `${hours} hour${hours === 1 ? '' : 's'}`
  }

  if (seconds % 60 === 0) {
    const minutes = seconds / 60
    return `${minutes} minute${minutes === 1 ? '' : 's'}`
  }

  return `${seconds} seconds`
}

function triggerLabel(
  automation: ConsoleAutomation,
): string {
  if (
    automation.triggerType
    === 'contact_added'
  ) {
    return 'Contact added'
  }

  return automation.eventName === null
    ? 'API event'
    : `API event · ${automation.eventName}`
}

export function AutomationsPage() {
  const queryClient = useQueryClient()

  const automations = useQuery({
    queryKey: [
      'console-automations',
    ],
    queryFn: () =>
      apiGet<ConsoleAutomationListResponse>(
        '/console/automations',
      ),
    refetchInterval: 5000,
  })

  const senders = useQuery({
    queryKey: [
      'senders',
    ],
    queryFn: () =>
      apiGet<SenderIdentityListResponse>(
        '/api/v1/senders',
      ),
  })

  const templates = useQuery({
    queryKey: [
      'console-templates',
    ],
    queryFn: () =>
      apiGet<ConsoleEmailTemplateListResponse>(
        '/console/templates',
      ),
  })

  const [selectedId, setSelectedId] =
    useState<number | null>(null)
  const [name, setName] =
    useState('')
  const [triggerType, setTriggerType] =
    useState<ConsoleAutomationTriggerType>(
      'contact_added',
    )
  const [eventName, setEventName] =
    useState('')
  const [delaySeconds, setDelaySeconds] =
    useState('0')
  const [senderId, setSenderId] =
    useState('')
  const [templateId, setTemplateId] =
    useState('')
  const [error, setError] =
    useState<string | null>(null)

  const items =
    automations.data?.items ?? []

  const selected = useMemo(
    () =>
      items.find(
        (item) =>
          item.id === selectedId,
      ) ?? null,
    [
      items,
      selectedId,
    ],
  )

  useEffect(
    () => {
      if (
        selectedId === null
        && items.length > 0
      ) {
        setSelectedId(
          items[0].id,
        )
      }

      if (
        selectedId !== null
        && items.length > 0
        && !items.some(
          (item) =>
            item.id === selectedId,
        )
      ) {
        setSelectedId(
          items[0].id,
        )
      }

      if (
        items.length === 0
        && selectedId !== null
      ) {
        setSelectedId(null)
      }
    },
    [
      items,
      selectedId,
    ],
  )

  const refresh = async () => {
    await queryClient.invalidateQueries({
      queryKey: [
        'console-automations',
      ],
    })
  }

  const create = useMutation({
    mutationFn: () =>
      apiPost<ConsoleAutomation>(
        '/console/automations',
        {
          name:
            name.trim(),
          triggerType,
          eventName:
            triggerType === 'api_event'
              ? eventName.trim()
              : null,
          delaySeconds:
            Number(
              delaySeconds,
            ),
          senderId:
            Number(
              senderId,
            ),
          templateId:
            Number(
              templateId,
            ),
        },
      ),
    onSuccess: async (created) => {
      setSelectedId(
        created.id,
      )
      setName('')
      setEventName('')
      setDelaySeconds('0')
      setError(null)
      await refresh()
    },
    onError: (caught) =>
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to create automation.',
      ),
  })

  const setStatus = (
    action: 'pause' | 'resume',
  ) =>
    useMutation({
      mutationFn: (
        id: number,
      ) =>
        apiPost<ConsoleAutomation>(
          `/console/automations/${id}/${action}`,
        ),
      onSuccess: async () => {
        setError(null)
        await refresh()
      },
      onError: (caught) =>
        setError(
          caught instanceof Error
            ? caught.message
            : `Unable to ${action} automation.`,
        ),
    })

  const pause =
    setStatus('pause')
  const resume =
    setStatus('resume')

  const remove = useMutation({
    mutationFn: (
      id: number,
    ) =>
      apiDelete<void>(
        `/console/automations/${id}`,
      ),
    onSuccess: async () => {
      setSelectedId(null)
      setError(null)
      await refresh()
    },
    onError: (caught) =>
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to delete automation.',
      ),
  })

  const delayNumber =
    Number(
      delaySeconds,
    )

  const createDisabled =
    name.trim() === ''
    || senderId === ''
    || templateId === ''
    || !Number.isInteger(
      delayNumber,
    )
    || delayNumber < 0
    || delayNumber > 31536000
    || (
      triggerType === 'api_event'
      && !/^[a-z][a-z0-9_.-]{0,63}$/.test(
        eventName.trim(),
      )
    )
    || create.isPending

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Lifecycle
          </span>

          <h1>Automations</h1>

          <p>
            Send a template when a contact is
            added or when your application posts
            an authenticated API event.
          </p>
        </div>
      </header>

      {error && (
        <div className="inline-error campaign-error">
          {error}
        </div>
      )}

      <div className="campaign-grid">
        <section className="panel">
          <header className="panel__header">
            <div>
              <h2>
                <Workflow size={15} />
                Automations
              </h2>
              <p>
                {items.length} saved
              </p>
            </div>
          </header>

          <div className="campaign-list">
            {items.map(
              (automation) => (
                <button
                  className={
                    automation.id
                    === selectedId
                      ? 'campaign-row campaign-row--active'
                      : 'campaign-row'
                  }
                  key={automation.id}
                  onClick={() =>
                    setSelectedId(
                      automation.id,
                    )
                  }
                  type="button"
                >
                  <strong>
                    {automation.name}
                  </strong>

                  <span>
                    {automation.status}
                    {' · '}
                    {triggerLabel(
                      automation,
                    )}
                    {' · '}
                    {formatDelay(
                      automation.delaySeconds,
                    )}
                  </span>
                </button>
              ),
            )}

            {!automations.isLoading
              && items.length === 0 && (
                <div className="template-empty">
                  No automations yet.
                </div>
              )}
          </div>
        </section>

        <section className="panel">
          <header className="panel__header">
            <div>
              <h2>
                <Plus size={15} />
                New automation
              </h2>

              <p>
                Sender and template are
                snapshotted when each trigger
                creates a job.
              </p>
            </div>
          </header>

          <div className="campaign-form">
            <label className="field">
              <span>Name</span>
              <input
                maxLength={160}
                onChange={(event) =>
                  setName(
                    event.target.value,
                  )
                }
                value={name}
              />
            </label>

            <label className="field">
              <span>Trigger</span>
              <select
                onChange={(event) =>
                  setTriggerType(
                    event.target.value as
                      ConsoleAutomationTriggerType,
                  )
                }
                value={triggerType}
              >
                <option value="contact_added">
                  Contact added
                </option>
                <option value="api_event">
                  API event
                </option>
              </select>
            </label>

            {triggerType === 'api_event' && (
              <label className="field">
                <span>Event name</span>
                <input
                  autoComplete="off"
                  maxLength={64}
                  onChange={(event) =>
                    setEventName(
                      event.target.value,
                    )
                  }
                  placeholder="customer.signup"
                  spellCheck={false}
                  value={eventName}
                />
                <small>
                  Lowercase letters, numbers,
                  dots, underscores and hyphens.
                </small>
              </label>
            )}

            <label className="field">
              <span>Delay in seconds</span>
              <input
                max={31536000}
                min={0}
                onChange={(event) =>
                  setDelaySeconds(
                    event.target.value,
                  )
                }
                step={1}
                type="number"
                value={delaySeconds}
              />
              <small>
                0 = immediate · J+3 = 259200.
              </small>
            </label>

            <label className="field">
              <span>Sender</span>
              <select
                onChange={(event) =>
                  setSenderId(
                    event.target.value,
                  )
                }
                value={senderId}
              >
                <option value="">
                  Select sender…
                </option>

                {senders.data?.items
                  .filter(
                    (sender) =>
                      sender.authorized,
                  )
                  .map(
                    (sender) => (
                      <option
                        key={sender.id}
                        value={sender.id}
                      >
                        {sender.email}
                      </option>
                    ),
                  )}
              </select>
            </label>

            <label className="field">
              <span>Template</span>
              <select
                onChange={(event) =>
                  setTemplateId(
                    event.target.value,
                  )
                }
                value={templateId}
              >
                <option value="">
                  Select template…
                </option>

                {templates.data?.items.map(
                  (template) => (
                    <option
                      key={template.id}
                      value={template.id}
                    >
                      {template.name}
                      {' · v'}
                      {template.version}
                    </option>
                  ),
                )}
              </select>
            </label>

            <button
              className="button button--primary"
              disabled={createDisabled}
              onClick={() =>
                create.mutate()
              }
              type="button"
            >
              <Plus size={13} />
              Create automation
            </button>
          </div>
        </section>
      </div>

      {selected && (
        <section className="panel campaign-control">
          <header className="panel__header panel__header--row">
            <div>
              <h2>{selected.name}</h2>

              <p>
                {triggerLabel(
                  selected,
                )}
                {' · '}
                {formatDelay(
                  selected.delaySeconds,
                )}
                {' · '}
                {selected.jobCount}
                {' job'}
                {selected.jobCount === 1
                  ? ''
                  : 's'}
              </p>
            </div>

            <div className="button-group">
              {selected.status === 'active'
                ? (
                  <button
                    className="button button--secondary"
                    disabled={pause.isPending}
                    onClick={() =>
                      pause.mutate(
                        selected.id,
                      )
                    }
                    type="button"
                  >
                    <Pause size={13} />
                    Pause
                  </button>
                )
                : (
                  <button
                    className="button button--primary"
                    disabled={resume.isPending}
                    onClick={() =>
                      resume.mutate(
                        selected.id,
                      )
                    }
                    type="button"
                  >
                    <Play size={13} />
                    Resume
                  </button>
                )}

              <button
                className="button button--secondary"
                disabled={
                  selected.jobCount > 0
                  || remove.isPending
                }
                onClick={() =>
                  remove.mutate(
                    selected.id,
                  )
                }
                title={
                  selected.jobCount > 0
                    ? 'Pause automations with execution history instead of deleting them.'
                    : 'Delete automation'
                }
                type="button"
              >
                <Trash2 size={13} />
                Delete
              </button>
            </div>
          </header>

          <div className="campaign-control__body">
            <div className="campaign-progress">
              <div>
                <strong>
                  {selected.status === 'active'
                    ? 'Active'
                    : 'Paused'}
                </strong>
                <span>
                  Future matching triggers
                  {selected.status === 'active'
                    ? ' create jobs.'
                    : ' are ignored.'}
                </span>
              </div>

              <Clock3 size={22} />
            </div>

            <div className="template-history__list">
              <div className="template-history__row">
                <strong>Sender</strong>
                <code>
                  {selected.senderEmail
                    ?? `#${selected.senderId ?? 'unavailable'}`}
                </code>
              </div>

              <div className="template-history__row">
                <strong>Template</strong>
                <code>
                  {selected.templateName
                    ?? `#${selected.templateId ?? 'unavailable'}`}
                </code>
              </div>

              {selected.triggerType === 'api_event' && (
                <div className="template-history__row">
                  <strong>API endpoint</strong>
                  <code>
                    /api/v1/automation-events/
                    {selected.eventName}
                  </code>
                </div>
              )}
            </div>
          </div>
        </section>
      )}
    </div>
  )
}
