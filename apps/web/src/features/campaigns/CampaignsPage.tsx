import {
  Eye,
  MailCheck,
  Pause,
  Play,
  Plus,
  Send,
  Square,
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
  ConsoleCampaign,
  ConsoleCampaignListResponse,
  ConsoleCampaignPreviewResponse,
  ConsoleContactListListResponse,
  ConsoleEmailTemplateListResponse,
  SenderIdentityListResponse,
  SendMessageResponse,
} from '../../lib/api/types'

function previewDocument(
  html: string,
): string {
  return `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'">${html}`
}

export function CampaignsPage() {
  const queryClient = useQueryClient()

  const campaigns = useQuery({
    queryKey: ['console-campaigns'],
    queryFn: () =>
      apiGet<ConsoleCampaignListResponse>(
        '/console/campaigns',
      ),
    refetchInterval: 5000,
  })

  const senders = useQuery({
    queryKey: ['senders'],
    queryFn: () =>
      apiGet<SenderIdentityListResponse>(
        '/api/v1/senders',
      ),
  })

  const templates = useQuery({
    queryKey: ['console-templates'],
    queryFn: () =>
      apiGet<ConsoleEmailTemplateListResponse>(
        '/console/templates',
      ),
  })

  const lists = useQuery({
    queryKey: ['console-contact-lists'],
    queryFn: () =>
      apiGet<ConsoleContactListListResponse>(
        '/console/contact-lists',
      ),
  })

  const [selectedId, setSelectedId] =
    useState<number | null>(null)
  const [name, setName] = useState('')
  const [senderId, setSenderId] =
    useState('')
  const [templateId, setTemplateId] =
    useState('')
  const [listId, setListId] =
    useState('')
  const [trackingEnabled, setTrackingEnabled] =
    useState(false)
  const [scheduledFor, setScheduledFor] =
    useState('')
  const [variablesRaw, setVariablesRaw] =
    useState('{\n  "first_name": "Ada"\n}')
  const [testEmail, setTestEmail] =
    useState('')
  const [testName, setTestName] =
    useState('')
  const [preview, setPreview] =
    useState<ConsoleCampaignPreviewResponse | null>(
      null,
    )
  const [error, setError] =
    useState<string | null>(null)

  const items =
    campaigns.data?.items ?? []

  const selected = useMemo(
    () =>
      items.find(
        (item) =>
          item.id === selectedId,
      ) ?? null,
    [items, selectedId],
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
    },
    [
      items,
      selectedId,
    ],
  )

  const refresh = async () => {
    await queryClient.invalidateQueries({
      queryKey: ['console-campaigns'],
    })
  }

  const parseVariables = () => {
    const value: unknown =
      JSON.parse(
        variablesRaw.trim() === ''
          ? '{}'
          : variablesRaw,
      )

    if (
      value === null
      || Array.isArray(value)
      || typeof value !== 'object'
    ) {
      throw new Error(
        'Variables must be a JSON object.',
      )
    }

    return value as Record<
      string,
      string | number | boolean | null
    >
  }

  const create = useMutation({
    mutationFn: () =>
      apiPost<ConsoleCampaign>(
        '/console/campaigns',
        {
          name: name.trim(),
          senderId: Number(senderId),
          templateId: Number(templateId),
          listId: Number(listId),
          trackingEnabled,
        },
      ),
    onSuccess: async (created) => {
      setSelectedId(created.id)
      setName('')
      setTrackingEnabled(false)
      setError(null)
      await refresh()
    },
    onError: (caught) =>
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to create campaign.',
      ),
  })

  const previewMutation = useMutation({
    mutationFn: () => {
      if (!selected) {
        throw new Error(
          'Select a campaign.',
        )
      }

      return apiPost<ConsoleCampaignPreviewResponse>(
        `/console/campaigns/${selected.id}/preview`,
        {
          variables:
            parseVariables(),
        },
      )
    },
    onSuccess: (value) => {
      setPreview(value)
      setError(null)
    },
    onError: (caught) =>
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to preview campaign.',
      ),
  })

  const testSend = useMutation({
    mutationFn: () => {
      if (!selected) {
        throw new Error(
          'Select a campaign.',
        )
      }

      return apiPost<SendMessageResponse>(
        `/console/campaigns/${selected.id}/test`,
        {
          email:
            testEmail.trim(),
          name:
            testName.trim() === ''
              ? undefined
              : testName.trim(),
          variables:
            parseVariables(),
        },
      )
    },
    onSuccess: () => {
      setError(null)
    },
    onError: (caught) =>
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to send campaign test.',
      ),
  })

  const mutateState = (
    action:
      | 'schedule'
      | 'pause'
      | 'resume'
      | 'cancel',
  ) =>
    useMutation({
      mutationFn: () => {
        if (!selected) {
          throw new Error(
            'Select a campaign.',
          )
        }

        return apiPost<ConsoleCampaign>(
          `/console/campaigns/${selected.id}/${action}`,
          action === 'schedule'
            ? {
                scheduledFor:
                  scheduledFor === ''
                    ? null
                    : new Date(
                        scheduledFor,
                      ).toISOString(),
              }
            : undefined,
        )
      },
      onSuccess: async () => {
        setError(null)
        await refresh()
      },
      onError: (caught) =>
        setError(
          caught instanceof Error
            ? caught.message
            : `Unable to ${action} campaign.`,
        ),
    })

  const schedule = mutateState('schedule')
  const pause = mutateState('pause')
  const resume = mutateState('resume')
  const cancel = mutateState('cancel')

  const progress =
    selected
      && selected.recipientCount > 0
      ? Math.round(
          (
            selected.processedCount
            / selected.recipientCount
          ) * 100,
        )
      : 0

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Broadcast
          </span>

          <h1>Campaigns</h1>

          <p>
            Snapshot an audience, preview,
            test, schedule and process in
            resumable batches.
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
              <h2>Campaigns</h2>
              <p>{items.length} saved</p>
            </div>
          </header>

          <div className="campaign-list">
            {items.map(
              (campaign) => (
                <button
                  className={
                    campaign.id
                    === selectedId
                      ? 'campaign-row campaign-row--active'
                      : 'campaign-row'
                  }
                  key={campaign.id}
                  onClick={() =>
                    setSelectedId(
                      campaign.id,
                    )
                  }
                  type="button"
                >
                  <strong>
                    {campaign.name}
                  </strong>

                  <span>
                    {campaign.status}
                    {' · '}
                    {campaign.processedCount}
                    /
                    {campaign.recipientCount}
                  </span>
                </button>
              ),
            )}

            {!campaigns.isLoading
              && items.length === 0 && (
                <div className="template-empty">
                  No campaigns yet.
                </div>
              )}
          </div>
        </section>

        <section className="panel">
          <header className="panel__header">
            <div>
              <h2>
                <Plus size={15} />
                New campaign
              </h2>

              <p>
                Select an authorized sender,
                template and contact list.
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

            <label className="field">
              <span>List</span>
              <select
                onChange={(event) =>
                  setListId(
                    event.target.value,
                  )
                }
                value={listId}
              >
                <option value="">
                  Select list…
                </option>

                {lists.data?.items.map(
                  (list) => (
                    <option
                      key={list.id}
                      value={list.id}
                    >
                      {list.name}
                      {' · '}
                      {list.contactCount}
                    </option>
                  ),
                )}
              </select>
            </label>

            <label className="campaign-tracking-option">
              <input
                checked={trackingEnabled}
                onChange={(event) =>
                  setTrackingEnabled(
                    event.target.checked,
                  )
                }
                type="checkbox"
              />

              <span>
                <strong>
                  Track opens and clicks
                </strong>

                <small>
                  Optional. Only HTML campaign
                  messages are instrumented.
                </small>
              </span>
            </label>

            <button
              className="button button--primary"
              disabled={
                name.trim() === ''
                || senderId === ''
                || templateId === ''
                || listId === ''
                || create.isPending
              }
              onClick={() =>
                create.mutate()
              }
              type="button"
            >
              <Plus size={13} />
              Create draft
            </button>
          </div>
        </section>
      </div>

      {selected && (
        <>
          <section className="panel campaign-control">
            <header className="panel__header panel__header--row">
              <div>
                <h2>{selected.name}</h2>
                <p>
                  Status: {selected.status}
                  {' · Tracking '}
                  {selected.trackingEnabled
                    ? 'on'
                    : 'off'}
                </p>
              </div>

              <div className="button-group">
                {selected.status === 'draft' && (
                  <button
                    className="button button--primary"
                    disabled={schedule.isPending}
                    onClick={() =>
                      schedule.mutate()
                    }
                    type="button"
                  >
                    <Send size={13} />
                    Schedule
                  </button>
                )}

                {[
                  'scheduled',
                  'ready',
                  'processing',
                ].includes(
                  selected.status,
                ) && (
                  <button
                    className="button button--secondary"
                    onClick={() =>
                      pause.mutate()
                    }
                    type="button"
                  >
                    <Pause size={13} />
                    Pause
                  </button>
                )}

                {selected.status === 'paused' && (
                  <button
                    className="button button--primary"
                    onClick={() =>
                      resume.mutate()
                    }
                    type="button"
                  >
                    <Play size={13} />
                    Resume
                  </button>
                )}

                {![
                  'completed',
                  'cancelled',
                ].includes(
                  selected.status,
                ) && (
                  <button
                    className="button button--secondary"
                    onClick={() =>
                      cancel.mutate()
                    }
                    type="button"
                  >
                    <Square size={13} />
                    Cancel
                  </button>
                )}
              </div>
            </header>

            <div className="campaign-control__body">
              <div className="campaign-progress">
                <div>
                  <strong>
                    {selected.processedCount}
                    {' / '}
                    {selected.recipientCount}
                  </strong>
                  <span>{progress}% processed</span>
                </div>

                <progress
                  max={100}
                  value={progress}
                />
              </div>

              {selected.status === 'draft' && (
                <label className="field">
                  <span>
                    Schedule for
                  </span>

                  <input
                    onChange={(event) =>
                      setScheduledFor(
                        event.target.value,
                      )
                    }
                    type="datetime-local"
                    value={scheduledFor}
                  />

                  <small>
                    Leave empty to send now.
                  </small>
                </label>
              )}

              {selected.lastError && (
                <div className="inline-error">
                  {selected.lastError}
                </div>
              )}
            </div>
          </section>

          {selected.status === 'draft' && (
            <div className="campaign-preview-grid">
              <section className="panel">
                <header className="panel__header">
                  <div>
                    <h2>Preview & test</h2>
                    <p>
                      Draft-only, before the
                      immutable snapshot.
                    </p>
                  </div>
                </header>

                <div className="campaign-form">
                  <label className="field">
                    <span>
                      Variables JSON
                    </span>

                    <textarea
                      onChange={(event) =>
                        setVariablesRaw(
                          event.target.value,
                        )
                      }
                      rows={8}
                      value={variablesRaw}
                    />
                  </label>

                  <button
                    className="button button--secondary"
                    onClick={() =>
                      previewMutation.mutate()
                    }
                    type="button"
                  >
                    <Eye size={13} />
                    Render preview
                  </button>

                  <div className="send-form__two">
                    <label className="field">
                      <span>Test email</span>

                      <input
                        onChange={(event) =>
                          setTestEmail(
                            event.target.value,
                          )
                        }
                        type="email"
                        value={testEmail}
                      />
                    </label>

                    <label className="field">
                      <span>Test name</span>

                      <input
                        onChange={(event) =>
                          setTestName(
                            event.target.value,
                          )
                        }
                        value={testName}
                      />
                    </label>
                  </div>

                  <button
                    className="button button--primary"
                    disabled={
                      testEmail.trim() === ''
                      || testSend.isPending
                    }
                    onClick={() =>
                      testSend.mutate()
                    }
                    type="button"
                  >
                    <MailCheck size={13} />
                    Send test
                  </button>

                  {testSend.data && (
                    <div className="send-success">
                      <div>
                        <strong>
                          Test accepted
                        </strong>
                        <span>
                          Message #
                          {testSend.data.messageId}
                        </span>
                      </div>
                    </div>
                  )}
                </div>
              </section>

              <section className="panel template-preview-panel">
                <header className="panel__header">
                  <div>
                    <h2>Preview</h2>
                    <p>Sandboxed rendering</p>
                  </div>
                </header>

                <div className="template-preview">
                  {preview
                    ? (
                        <>
                          <div className="template-preview__subject">
                            <span>Subject</span>
                            <strong>
                              {preview.subject}
                            </strong>
                          </div>

                          {preview.html
                            ? (
                                <iframe
                                  sandbox=""
                                  srcDoc={
                                    previewDocument(
                                      preview.html,
                                    )
                                  }
                                  title="Campaign preview"
                                />
                              )
                            : (
                                <pre>
                                  {preview.text ?? ''}
                                </pre>
                              )}
                        </>
                      )
                    : (
                        <div className="template-empty">
                          Render to preview.
                        </div>
                      )}
                </div>
              </section>
            </div>
          )}
        </>
      )}
    </div>
  )
}
