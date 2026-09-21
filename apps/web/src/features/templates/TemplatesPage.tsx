import {
  Copy,
  Eye,
  History,
  Monitor,
  Plus,
  Save,
  Send,
  Smartphone,
} from 'lucide-react'
import {
  useMutation,
  useQuery,
  useQueryClient,
} from '@tanstack/react-query'
import {
  Link,
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
  ConsoleEmailTemplate,
  ConsoleEmailTemplateHistoryResponse,
  ConsoleEmailTemplateListResponse,
  ConsoleEmailTemplateRenderResponse,
  ConsoleVisualEmailDocument,
} from '../../lib/api/types'
import {
  defaultVisualDocument,
  VisualEmailEditor,
  visualDocumentReady,
} from './VisualEmailEditor'

function previewDocument(
  html: string,
): string {
  return `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">${html}`
}

export function TemplatesPage() {
  const queryClient = useQueryClient()

  const templates = useQuery({
    queryKey: ['console-templates'],
    queryFn: () =>
      apiGet<ConsoleEmailTemplateListResponse>(
        '/console/templates',
      ),
  })

  const [selectedId, setSelectedId] =
    useState<number | null>(null)
  const [creating, setCreating] =
    useState(false)
  const [name, setName] = useState('')
  const [subject, setSubject] = useState('')
  const [textBody, setTextBody] = useState('')
  const [htmlBody, setHtmlBody] = useState('')
  const [editorMode, setEditorMode] =
    useState<'visual' | 'html'>('visual')
  const [visualDocument, setVisualDocument] =
    useState<ConsoleVisualEmailDocument>(
      () => defaultVisualDocument(),
    )
  const [variables, setVariables] =
    useState<Record<string, string>>({})
  const [preview, setPreview] =
    useState<ConsoleEmailTemplateRenderResponse | null>(null)
  const [mobile, setMobile] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const items = templates.data?.items ?? []

  const selected = useMemo(
    () =>
      items.find(
        (item) => item.id === selectedId,
      ) ?? null,
    [items, selectedId],
  )

  useEffect(() => {
    if (
      !creating
      && selectedId === null
      && items.length > 0
    ) {
      setSelectedId(items[0].id)
    }
  }, [
    creating,
    items,
    selectedId,
  ])

  useEffect(() => {
    if (!selected) {
      return
    }

    setSubject(selected.subject)
    setTextBody(selected.text ?? '')
    setHtmlBody(selected.html ?? '')
    setEditorMode(
      selected.visual
        ? 'visual'
        : 'html',
    )
    setVisualDocument(
      selected.visual
        ?? defaultVisualDocument(),
    )
    setVariables(
      Object.fromEntries(
        selected.variables.map(
          (variable) => [
            variable,
            variable === 'first_name'
              ? 'Ada'
              : `sample_${variable}`,
          ],
        ),
      ),
    )
    setPreview(null)
    setError(null)
  }, [selected])

  const history = useQuery({
    queryKey: [
      'console-template-history',
      selectedId,
    ],
    enabled: selectedId !== null,
    queryFn: () =>
      apiGet<ConsoleEmailTemplateHistoryResponse>(
        `/console/templates/${selectedId}/history`,
      ),
  })

  const refresh = async () => {
    await queryClient.invalidateQueries({
      queryKey: ['console-templates'],
    })

    if (selectedId !== null) {
      await queryClient.invalidateQueries({
        queryKey: [
          'console-template-history',
          selectedId,
        ],
      })
    }
  }

  const contentPayload = () => ({
    subject,
    text: textBody === ''
      ? null
      : textBody,
    html:
      editorMode === 'visual'
        ? null
        : (
            htmlBody === ''
              ? null
              : htmlBody
          ),
    visual:
      editorMode === 'visual'
        ? visualDocument
        : null,
  })

  const create = useMutation({
    mutationFn: () =>
      apiPost<ConsoleEmailTemplate>(
        '/console/templates',
        {
          name: name.trim(),
          ...contentPayload(),
        },
      ),
    onSuccess: async (created) => {
      setName('')
      setCreating(false)
      setSelectedId(created.id)
      await refresh()
    },
    onError: (caught) =>
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to create template.',
      ),
  })

  const save = useMutation({
    mutationFn: () => {
      if (!selected) {
        throw new Error('Select a template.')
      }

      return apiPost<ConsoleEmailTemplate>(
        `/console/templates/${selected.id}/versions`,
        contentPayload(),
      )
    },
    onSuccess: async () => {
      setPreview(null)
      await refresh()
    },
    onError: (caught) =>
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to save template.',
      ),
  })

  const duplicate = useMutation({
    mutationFn: () => {
      if (!selected) {
        throw new Error('Select a template.')
      }

      return apiPost<ConsoleEmailTemplate>(
        `/console/templates/${selected.id}/duplicate`,
      )
    },
    onSuccess: async (created) => {
      setCreating(false)
      setSelectedId(created.id)
      await refresh()
    },
    onError: (caught) =>
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to duplicate template.',
      ),
  })

  const render = useMutation({
    mutationFn: () => {
      if (!selected) {
        throw new Error('Select a template.')
      }

      return apiPost<ConsoleEmailTemplateRenderResponse>(
        `/console/templates/${selected.id}/render`,
        {
          variables,
        },
      )
    },
    onSuccess: (rendered) => {
      setPreview(rendered)
      setError(null)
    },
    onError: (caught) =>
      setError(
        caught instanceof Error
          ? caught.message
          : 'Unable to render template.',
      ),
  })

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Content
          </span>

          <h1>
            Email templates
          </h1>

          <p>
            Versioned workspace templates
            with variables, preview and
            duplication.
          </p>
        </div>
      </header>

      {error && (
        <div className="inline-error template-error">
          {error}
        </div>
      )}

      <div className="template-workspace">
        <section className="panel template-list-panel">
          <header className="panel__header panel__header--row">
            <div>
              <h2>Templates</h2>
              <p>{items.length} saved</p>
            </div>

            <button
              className="button button--secondary"
              onClick={() => {
                setCreating(true)
                setSelectedId(null)
                setName('')
                setSubject('')
                setTextBody('')
                setHtmlBody('')
                setEditorMode('visual')
                setVisualDocument(
                  defaultVisualDocument(),
                )
                setPreview(null)
              }}
              type="button"
            >
              <Plus size={13} />
              New
            </button>
          </header>

          <div className="template-list">
            {items.map((template) => (
              <button
                className={
                  template.id === selectedId
                    ? 'template-list__item template-list__item--active'
                    : 'template-list__item'
                }
                key={template.id}
                onClick={() => {
                  setCreating(false)
                  setSelectedId(template.id)
                }}
                type="button"
              >
                <strong>{template.name}</strong>
                <span>
                  v{template.version}
                  {' · '}
                  {template.variables.length}
                  {' vars'}
                </span>
              </button>
            ))}

            {!templates.isLoading
              && items.length === 0 && (
                <span className="table-muted template-list__empty">
                  No templates yet.
                </span>
              )}
          </div>
        </section>

        <section className="panel">
          <header className="panel__header panel__header--row">
            <div>
              <h2>
                {selected?.name ?? 'New template'}
              </h2>

              <p>
                {selected
                  ? `Latest version v${selected.version}`
                  : 'Create version 1'}
              </p>
            </div>

            {selected && (
              <div className="button-group">
                <button
                  className="button button--secondary"
                  disabled={duplicate.isPending}
                  onClick={() => duplicate.mutate()}
                  type="button"
                >
                  <Copy size={13} />
                  Duplicate
                </button>

                <Link
                  className="button button--secondary"
                  to={`/send?template=${selected.id}`}
                >
                  <Send size={13} />
                  Use in Send API
                </Link>
              </div>
            )}
          </header>

          <div className="template-editor__body">
            {!selected && (
              <label className="field">
                <span>Name</span>
                <input
                  maxLength={160}
                  onChange={(event) =>
                    setName(event.target.value)
                  }
                  placeholder="Welcome email"
                  value={name}
                />
              </label>
            )}

            <label className="field">
              <span>Subject</span>
              <input
                maxLength={255}
                onChange={(event) =>
                  setSubject(event.target.value)
                }
                placeholder="Hello {{first_name}}"
                value={subject}
              />
            </label>

            <div className="template-editor-mode">
              <div className="template-editor-mode__buttons">
                <button
                  className={
                    editorMode === 'visual'
                      ? 'copy-button copy-button--active'
                      : 'copy-button'
                  }
                  onClick={() =>
                    setEditorMode('visual')
                  }
                  type="button"
                >
                  Visual
                </button>

                <button
                  className={
                    editorMode === 'html'
                      ? 'copy-button copy-button--active'
                      : 'copy-button'
                  }
                  onClick={() =>
                    setEditorMode('html')
                  }
                  type="button"
                >
                  HTML
                </button>
              </div>

              <small>
                Visual mode stores structured blocks and
                lets the API generate the send HTML.
                Switching modes does not convert unsaved
                edits.
              </small>
            </div>

            {editorMode === 'visual'
              ? (
                  <>
                    <VisualEmailEditor
                      document={visualDocument}
                      onChange={setVisualDocument}
                    />

                    <label className="field">
                      <span>Text fallback</span>
                      <textarea
                        onChange={(event) =>
                          setTextBody(
                            event.target.value,
                          )
                        }
                        rows={7}
                        value={textBody}
                      />
                      <small>
                        Optional plain-text alternative.
                      </small>
                    </label>
                  </>
                )
              : (
                  <div className="send-content-grid">
                    <label className="field">
                      <span>Text body</span>
                      <textarea
                        onChange={(event) =>
                          setTextBody(
                            event.target.value,
                          )
                        }
                        rows={12}
                        value={textBody}
                      />
                    </label>

                    <label className="field">
                      <span>HTML body</span>
                      <textarea
                        onChange={(event) =>
                          setHtmlBody(
                            event.target.value,
                          )
                        }
                        rows={12}
                        value={htmlBody}
                      />
                    </label>
                  </div>
                )}

            <button
              className="button button--primary template-save"
              disabled={
                subject.trim() === ''
                || (
                  editorMode === 'visual'
                    ? !visualDocumentReady(
                        visualDocument,
                      )
                    : (
                        textBody === ''
                        && htmlBody === ''
                      )
                )
                || (
                  selected === null
                  && name.trim() === ''
                )
              }
              onClick={() =>
                selected
                  ? save.mutate()
                  : create.mutate()
              }
              type="button"
            >
              {selected
                ? <Save size={13} />
                : <Plus size={13} />}
              {selected
                ? 'Save new version'
                : 'Create template'}
            </button>
          </div>
        </section>
      </div>

      {selected && (
        <>
          <div className="template-preview-grid">
            <section className="panel">
              <header className="panel__header">
                <div>
                  <h2>Preview variables</h2>
                  <p>
                    Rendered server-side.
                  </p>
                </div>
              </header>

              <div className="template-variable-form">
                {selected.variables.map(
                  (variable) => (
                    <label
                      className="field"
                      key={variable}
                    >
                      <span>{variable}</span>
                      <input
                        onChange={(event) =>
                          setVariables(
                            (current) => ({
                              ...current,
                              [variable]:
                                event.target.value,
                            }),
                          )
                        }
                        value={
                          variables[variable] ?? ''
                        }
                      />
                    </label>
                  ),
                )}

                <button
                  className="button button--primary"
                  onClick={() => render.mutate()}
                  type="button"
                >
                  <Eye size={13} />
                  Render preview
                </button>
              </div>
            </section>

            <section className="panel template-preview-panel">
              <header className="panel__header panel__header--row">
                <div>
                  <h2>Preview</h2>
                  <p>Desktop / mobile</p>
                </div>

                <div className="template-device-toggle">
                  <button
                    className={
                      mobile
                        ? 'copy-button'
                        : 'copy-button copy-button--active'
                    }
                    onClick={() => setMobile(false)}
                    type="button"
                  >
                    <Monitor size={14} />
                  </button>

                  <button
                    className={
                      mobile
                        ? 'copy-button copy-button--active'
                        : 'copy-button'
                    }
                    onClick={() => setMobile(true)}
                    type="button"
                  >
                    <Smartphone size={14} />
                  </button>
                </div>
              </header>

              <div
                className={
                  mobile
                    ? 'template-preview template-preview--mobile'
                    : 'template-preview'
                }
              >
                {preview
                  ? (
                      <>
                        <div className="template-preview__subject">
                          <span>Subject</span>
                          <strong>{preview.subject}</strong>
                        </div>

                        {preview.html
                          ? (
                              <iframe
                                sandbox=""
                                srcDoc={previewDocument(preview.html)}
                                title="Template preview"
                              />
                            )
                          : (
                              <pre>{preview.text ?? ''}</pre>
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

          <section className="panel template-history">
            <header className="panel__header">
              <div>
                <h2>
                  <History size={15} />
                  Version history
                </h2>
                <p>Newest first.</p>
              </div>
            </header>

            <div className="template-history__list">
              {history.data?.items.map(
                (version) => (
                  <div
                    className="template-history__row"
                    key={version.id}
                  >
                    <strong>
                      Version {version.version}
                    </strong>
                    <code>{version.subject}</code>
                  </div>
                ),
              )}
            </div>
          </section>
        </>
      )}
    </div>
  )
}
