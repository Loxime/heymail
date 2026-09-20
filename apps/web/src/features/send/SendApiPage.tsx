import {
  AlertTriangle,
  CheckCircle2,
  Code2,
  FileText,
  Plus,
  RotateCcw,
  Send,
  Trash2,
} from 'lucide-react'
import {
  useMutation,
  useQuery,
} from '@tanstack/react-query'
import {
  Link,
  useSearchParams,
} from 'react-router-dom'
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
  ConsoleEmailTemplateListResponse,
  ConsoleEmailTemplateRenderResponse,
  EmailAddressPayload,
  SenderIdentityListResponse,
  SendMessagePayload,
  SendMessageResponse,
} from '../../lib/api/types'

interface RecipientDraft {
  email: string
  name: string
}

function newIdempotencyKey(): string {
  return `web-${crypto.randomUUID()}`
}

export function SendApiPage() {
  const [searchParams] = useSearchParams()

  const [fromEmail, setFromEmail] = useState('')
  const [fromName, setFromName] = useState('')
  const [replyTo, setReplyTo] = useState('')
  const [subject, setSubject] = useState('')
  const [textPart, setTextPart] = useState('')
  const [htmlPart, setHtmlPart] = useState('')
  const [
    selectedTemplateId,
    setSelectedTemplateId,
  ] = useState<number | null>(() => {
    const raw = searchParams.get('template')

    return raw !== null
      && /^[1-9][0-9]*$/.test(raw)
      ? Number(raw)
      : null
  })
  const [
    templateVariables,
    setTemplateVariables,
  ] = useState<Record<string, string>>({})
  const [
    idempotencyKey,
    setIdempotencyKey,
  ] = useState(newIdempotencyKey)
  const [
    recipients,
    setRecipients,
  ] = useState<RecipientDraft[]>([
    {
      email: '',
      name: '',
    },
  ])

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

  const authorizedSenders = useMemo(
    () =>
      senders.data?.items.filter(
        (sender) => sender.authorized,
      ) ?? [],
    [senders.data],
  )

  const selectedTemplate = useMemo(
    () =>
      templates.data?.items.find(
        (template) =>
          template.id === selectedTemplateId,
      ) ?? null,
    [
      selectedTemplateId,
      templates.data,
    ],
  )

  useEffect(() => {
    if (
      fromEmail === ''
      && authorizedSenders.length > 0
    ) {
      setFromEmail(
        authorizedSenders[0].email,
      )
    }
  }, [
    authorizedSenders,
    fromEmail,
  ])

  useEffect(() => {
    if (
      selectedTemplateId !== null
      && templates.data
      && !selectedTemplate
    ) {
      setSelectedTemplateId(null)
    }
  }, [
    selectedTemplate,
    selectedTemplateId,
    templates.data,
  ])

  useEffect(() => {
    if (!selectedTemplate) {
      setTemplateVariables({})
      return
    }

    setTemplateVariables(
      Object.fromEntries(
        selectedTemplate.variables.map(
          (variable) => [
            variable,
            '',
          ],
        ),
      ),
    )
  }, [selectedTemplate])

  const payload = useMemo<SendMessagePayload>(
    () => {
      const from: EmailAddressPayload = {
        email: fromEmail,
      }

      if (fromName.trim() !== '') {
        from.name = fromName.trim()
      }

      const to =
        recipients
          .filter(
            (recipient) =>
              recipient.email.trim() !== '',
          )
          .map(
            (recipient) => {
              const address: EmailAddressPayload = {
                email:
                  recipient.email.trim(),
              }

              if (
                recipient.name.trim()
                !== ''
              ) {
                address.name =
                  recipient.name.trim()
              }

              return address
            },
          )

      const result: SendMessagePayload = {
        from,
        to,
        subject,
      }

      if (textPart !== '') {
        result.text = textPart
      }

      if (htmlPart !== '') {
        result.html = htmlPart
      }

      if (replyTo.trim() !== '') {
        result.replyTo = {
          email: replyTo.trim(),
        }
      }

      return result
    },
    [
      fromEmail,
      fromName,
      htmlPart,
      recipients,
      replyTo,
      subject,
      textPart,
    ],
  )

  const mutation = useMutation({
    mutationFn: () =>
      apiPost<SendMessageResponse>(
        '/api/v1/send',
        payload,
        {
          'Idempotency-Key':
            idempotencyKey,
        },
      ),

    onSuccess: () => {
      setIdempotencyKey(
        newIdempotencyKey(),
      )
    },
  })

  const templateRender = useMutation({
    mutationFn: () => {
      if (!selectedTemplate) {
        throw new Error(
          'Select a template first.',
        )
      }

      return apiPost<ConsoleEmailTemplateRenderResponse>(
        `/console/templates/${selectedTemplate.id}/render`,
        {
          variables:
            templateVariables,
        },
      )
    },
    onSuccess: (rendered) => {
      setSubject(rendered.subject)
      setTextPart(rendered.text ?? '')
      setHtmlPart(rendered.html ?? '')
    },
  })

  const valid =
    fromEmail !== ''
    && subject.trim() !== ''
    && (
      textPart !== ''
      || htmlPart !== ''
    )
    && payload.to.length > 0
    && payload.to.length <= 50

  const updateRecipient = (
    index: number,
    field: keyof RecipientDraft,
    value: string,
  ) => {
    setRecipients(
      (current) =>
        current.map(
          (recipient, recipientIndex) =>
            recipientIndex === index
              ? {
                  ...recipient,
                  [field]: value,
                }
              : recipient,
        ),
    )
  }

  const addRecipient = () => {
    if (recipients.length >= 50) {
      return
    }

    setRecipients(
      (current) => [
        ...current,
        {
          email: '',
          name: '',
        },
      ],
    )
  }

  const removeRecipient = (
    index: number,
  ) => {
    if (recipients.length === 1) {
      return
    }

    setRecipients(
      (current) =>
        current.filter(
          (_, recipientIndex) =>
            recipientIndex !== index,
        ),
    )
  }

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Transactional
          </span>

          <h1>
            Send API
          </h1>

          <p>
            Compose and submit a real
            transactional message through
            the HeyMail API.
          </p>
        </div>
      </header>

      {authorizedSenders.length === 0
        && !senders.isLoading && (
          <div className="send-warning">
            <AlertTriangle size={18} />

            <div>
              <strong>
                No authorized sender
              </strong>

              <p>
                Configure a verified,
                DKIM-ready sender identity
                before sending mail.
              </p>
            </div>

            <Link
              className="button button--secondary"
              to="/senders"
            >
              Configure senders
            </Link>
          </div>
        )}

      <div className="send-layout">
        <form
          className="panel send-form"
          onSubmit={(event) => {
            event.preventDefault()

            if (valid) {
              mutation.mutate()
            }
          }}
        >
          <header className="panel__header">
            <div>
              <h2>
                Compose message
              </h2>

              <p>
                This performs a real API
                submission.
              </p>
            </div>
          </header>

          <div className="send-form__body">
            <div className="send-form__two">
              <label className="field">
                <span>From</span>

                <select
                  disabled={
                    authorizedSenders.length
                    === 0
                  }
                  onChange={(event) =>
                    setFromEmail(
                      event.target.value,
                    )
                  }
                  value={fromEmail}
                >
                  {authorizedSenders.length
                    === 0 && (
                      <option value="">
                        No authorized sender
                      </option>
                    )}

                  {authorizedSenders.map(
                    (sender) => (
                      <option
                        key={sender.id}
                        value={sender.email}
                      >
                        {sender.email}
                      </option>
                    ),
                  )}
                </select>
              </label>

              <label className="field">
                <span>From name</span>

                <input
                  maxLength={128}
                  onChange={(event) =>
                    setFromName(
                      event.target.value,
                    )
                  }
                  placeholder="HeyMail"
                  value={fromName}
                />
              </label>
            </div>

            <div className="send-section">
              <div className="send-section__heading">
                <div>
                  <strong>Recipients</strong>
                  <span>
                    {recipients.length}/50
                  </span>
                </div>

                <button
                  className="button button--secondary"
                  disabled={
                    recipients.length >= 50
                  }
                  onClick={addRecipient}
                  type="button"
                >
                  <Plus size={13} />
                  Add recipient
                </button>
              </div>

              <div className="recipient-list">
                {recipients.map(
                  (recipient, index) => (
                    <div
                      className="recipient-row"
                      key={index}
                    >
                      <input
                        onChange={(event) =>
                          updateRecipient(
                            index,
                            'email',
                            event.target.value,
                          )
                        }
                        placeholder="user@example.com"
                        type="email"
                        value={recipient.email}
                      />

                      <input
                        maxLength={128}
                        onChange={(event) =>
                          updateRecipient(
                            index,
                            'name',
                            event.target.value,
                          )
                        }
                        placeholder="Name (optional)"
                        value={recipient.name}
                      />

                      <button
                        aria-label="Remove recipient"
                        className="recipient-remove"
                        disabled={
                          recipients.length === 1
                        }
                        onClick={() =>
                          removeRecipient(index)
                        }
                        type="button"
                      >
                        <Trash2 size={14} />
                      </button>
                    </div>
                  ),
                )}
              </div>
            </div>

            <div className="send-section template-send-picker">
              <div className="send-section__heading">
                <div>
                  <strong>Email template</strong>
                  <span>Optional</span>
                </div>

                <Link
                  className="button button--secondary"
                  to="/templates"
                >
                  <FileText size={13} />
                  Manage templates
                </Link>
              </div>

              <label className="field">
                <span>Template</span>

                <select
                  onChange={(event) =>
                    setSelectedTemplateId(
                      event.target.value === ''
                        ? null
                        : Number(
                            event.target.value,
                          ),
                    )
                  }
                  value={
                    selectedTemplateId
                    ?? ''
                  }
                >
                  <option value="">
                    No template
                  </option>

                  {templates.data?.items.map(
                    (template) => (
                      <option
                        key={template.id}
                        value={template.id}
                      >
                        {template.name}
                        {' '}
                        (v{template.version})
                      </option>
                    ),
                  )}
                </select>
              </label>

              {selectedTemplate
                && selectedTemplate.variables.length > 0 && (
                  <div className="template-send-variables">
                    {selectedTemplate.variables.map(
                      (variable) => (
                        <label
                          className="field"
                          key={variable}
                        >
                          <span>{variable}</span>

                          <input
                            onChange={(event) =>
                              setTemplateVariables(
                                (current) => ({
                                  ...current,
                                  [variable]:
                                    event.target.value,
                                }),
                              )
                            }
                            value={
                              templateVariables[variable]
                              ?? ''
                            }
                          />
                        </label>
                      ),
                    )}
                  </div>
                )}

              {selectedTemplate && (
                <button
                  className="button button--secondary"
                  disabled={
                    templateRender.isPending
                  }
                  onClick={() =>
                    templateRender.mutate()
                  }
                  type="button"
                >
                  <FileText size={13} />
                  Apply rendered template
                </button>
              )}

              {templateRender.error
                instanceof Error && (
                  <div className="inline-error">
                    {
                      templateRender.error.message
                    }
                  </div>
                )}
            </div>

            <label className="field">
              <span>Reply-To</span>

              <input
                onChange={(event) =>
                  setReplyTo(
                    event.target.value,
                  )
                }
                placeholder="support@example.com (optional)"
                type="email"
                value={replyTo}
              />
            </label>

            <label className="field">
              <span>Subject</span>

              <input
                maxLength={255}
                onChange={(event) =>
                  setSubject(
                    event.target.value,
                  )
                }
                placeholder="Your message subject"
                value={subject}
              />
            </label>

            <div className="send-content-grid">
              <label className="field">
                <span>Text body</span>

                <textarea
                  onChange={(event) =>
                    setTextPart(
                      event.target.value,
                    )
                  }
                  placeholder="Plain-text content…"
                  rows={10}
                  value={textPart}
                />
              </label>

              <label className="field">
                <span>HTML body</span>

                <textarea
                  onChange={(event) =>
                    setHtmlPart(
                      event.target.value,
                    )
                  }
                  placeholder="<h1>Hello</h1>"
                  rows={10}
                  value={htmlPart}
                />
              </label>
            </div>

            <div className="idempotency-field">
              <div>
                <strong>
                  Idempotency key
                </strong>

                <p>
                  Kept across ambiguous
                  failures.
                </p>
              </div>

              <code>
                {idempotencyKey}
              </code>

              <button
                aria-label="Generate new idempotency key"
                className="copy-button"
                onClick={() =>
                  setIdempotencyKey(
                    newIdempotencyKey(),
                  )
                }
                type="button"
              >
                <RotateCcw size={13} />
              </button>
            </div>

            {mutation.error
              instanceof Error && (
                <div className="inline-error send-error">
                  {mutation.error.message}
                </div>
              )}

            {mutation.data && (
              <div className="send-success">
                <CheckCircle2 size={18} />

                <div>
                  <strong>
                    Message accepted
                  </strong>

                  <span>
                    Message #
                    {mutation.data.messageId}
                    {' · '}
                    {mutation.data.status}
                    {mutation.data.replayed
                      ? ' · replayed'
                      : ''}
                  </span>
                </div>

                <Link
                  className="button button--secondary"
                  to={
                    `/messages/${mutation.data.messageId}`
                  }
                >
                  View message
                </Link>
              </div>
            )}
          </div>

          <footer className="send-form__footer">
            <span>
              {payload.to.length}
              {' '}
              recipient
              {payload.to.length === 1
                ? ''
                : 's'}
            </span>

            <button
              className="button button--primary button--inline"
              disabled={
                !valid
                || mutation.isPending
              }
              type="submit"
            >
              <Send size={14} />
              {mutation.isPending
                ? 'Sending…'
                : 'Send message'}
            </button>
          </footer>
        </form>

        <aside className="panel send-preview">
          <header className="panel__header">
            <div>
              <h2>API request</h2>

              <p>
                Payload sent to
                POST /api/v1/send.
              </p>
            </div>
          </header>

          <div className="send-preview__meta">
            <span>
              <Code2 size={13} />
              POST
            </span>

            <code>/api/v1/send</code>
          </div>

          <pre>
            {JSON.stringify(
              payload,
              null,
              2,
            )}
          </pre>

          <div className="send-preview__security">
            <strong>
              Idempotent submission
            </strong>

            <span>
              Idempotency-Key is sent as
              an HTTP header.
            </span>
          </div>
        </aside>
      </div>
    </div>
  )
}
