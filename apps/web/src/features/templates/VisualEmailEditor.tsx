import {
  ArrowDown,
  ArrowUp,
  Columns2,
  GripVertical,
  Image as ImageIcon,
  MousePointerClick,
  Plus,
  Trash2,
  Type,
} from 'lucide-react'
import {
  useState,
} from 'react'

import type {
  ConsoleVisualEmailAlignment,
  ConsoleVisualEmailBlock,
  ConsoleVisualEmailDocument,
} from '../../lib/api/types'

type VisualBlockType =
  ConsoleVisualEmailBlock['type']

let blockSequence = 0

function nextBlockId(): string {
  blockSequence += 1

  return [
    'block',
    Date.now().toString(36),
    blockSequence.toString(36),
  ].join('_')
}

function newBlock(
  type: VisualBlockType,
): ConsoleVisualEmailBlock {
  const id = nextBlockId()

  switch (type) {
    case 'text':
      return {
        id,
        type,
        text: 'Write your message here.',
        align: 'left',
      }

    case 'image':
      return {
        id,
        type,
        url: 'https://example.com/image.png',
        alt: 'Image',
        align: 'center',
      }

    case 'button':
      return {
        id,
        type,
        label: 'Learn more',
        url: 'https://example.com',
        align: 'center',
      }

    case 'columns':
      return {
        id,
        type,
        columns: [
          {
            text: 'Left column',
            align: 'left',
          },
          {
            text: 'Right column',
            align: 'left',
          },
        ],
      }
  }
}

export function defaultVisualDocument():
ConsoleVisualEmailDocument {
  return {
    version: 1,
    blocks: [
      newBlock('text'),
    ],
  }
}

function validHttpsUrl(
  value: string,
): boolean {
  if (
    value === ''
    || value.length > 2048
    || /[\u0000-\u0020\u007f]/u.test(value)
    || value.includes('{{')
  ) {
    return false
  }

  try {
    const url = new URL(value)

    return (
      url.protocol === 'https:'
      && url.hostname !== ''
      && url.username === ''
      && url.password === ''
    )
  } catch {
    return false
  }
}

function validText(
  value: string,
): boolean {
  return (
    value.length <= 10000
    && !value.includes('\0')
    && !value.includes('[[HMHTML:')
  )
}

export function visualDocumentReady(
  document: ConsoleVisualEmailDocument,
): boolean {
  if (
    document.version !== 1
    || document.blocks.length < 1
    || document.blocks.length > 100
  ) {
    return false
  }

  const ids = new Set<string>()

  for (const block of document.blocks) {
    if (
      !/^[A-Za-z0-9_-]{1,64}$/u.test(block.id)
      || ids.has(block.id)
    ) {
      return false
    }

    ids.add(block.id)

    switch (block.type) {
      case 'text':
        if (!validText(block.text)) {
          return false
        }
        break

      case 'image':
        if (
          !validHttpsUrl(block.url)
          || block.alt.length > 255
          || block.alt.includes('\0')
        ) {
          return false
        }
        break

      case 'button':
        if (
          block.label.trim() === ''
          || block.label.length > 200
          || block.label.includes('\0')
          || block.label.includes('[[HMHTML:')
          || !validHttpsUrl(block.url)
        ) {
          return false
        }
        break

      case 'columns':
        if (
          block.columns.length !== 2
          || !block.columns.every(
            (column) => validText(column.text),
          )
        ) {
          return false
        }
        break
    }
  }

  return true
}

function blockLabel(
  block: ConsoleVisualEmailBlock,
): string {
  switch (block.type) {
    case 'text':
      return 'Text'

    case 'image':
      return 'Image'

    case 'button':
      return 'Button'

    case 'columns':
      return 'Columns'
  }
}

function alignOptions() {
  return (
    <>
      <option value="left">Left</option>
      <option value="center">Center</option>
      <option value="right">Right</option>
    </>
  )
}

interface VisualEmailEditorProps {
  document: ConsoleVisualEmailDocument
  onChange: (
    document: ConsoleVisualEmailDocument,
  ) => void
}

export function VisualEmailEditor({
  document,
  onChange,
}: VisualEmailEditorProps) {
  const [draggedId, setDraggedId] =
    useState<string | null>(null)

  const replaceBlock = (
    id: string,
    block: ConsoleVisualEmailBlock,
  ) => {
    onChange({
      ...document,
      blocks: document.blocks.map(
        (current) =>
          current.id === id
            ? block
            : current,
      ),
    })
  }

  const move = (
    id: string,
    delta: -1 | 1,
  ) => {
    const index =
      document.blocks.findIndex(
        (block) => block.id === id,
      )

    const target = index + delta

    if (
      index < 0
      || target < 0
      || target >= document.blocks.length
    ) {
      return
    }

    const blocks = [...document.blocks]
    const [block] = blocks.splice(index, 1)

    blocks.splice(target, 0, block)

    onChange({
      ...document,
      blocks,
    })
  }

  const dropBefore = (
    targetId: string,
  ) => {
    if (
      draggedId === null
      || draggedId === targetId
    ) {
      setDraggedId(null)
      return
    }

    const sourceIndex =
      document.blocks.findIndex(
        (block) => block.id === draggedId,
      )

    const targetIndex =
      document.blocks.findIndex(
        (block) => block.id === targetId,
      )

    if (
      sourceIndex < 0
      || targetIndex < 0
    ) {
      setDraggedId(null)
      return
    }

    const blocks = [...document.blocks]
    const [block] =
      blocks.splice(sourceIndex, 1)

    blocks.splice(
      targetIndex,
      0,
      block,
    )

    onChange({
      ...document,
      blocks,
    })

    setDraggedId(null)
  }

  const remove = (
    id: string,
  ) => {
    if (document.blocks.length === 1) {
      return
    }

    onChange({
      ...document,
      blocks:
        document.blocks.filter(
          (block) => block.id !== id,
        ),
    })
  }

  const add = (
    type: VisualBlockType,
  ) => {
    if (document.blocks.length >= 100) {
      return
    }

    onChange({
      ...document,
      blocks: [
        ...document.blocks,
        newBlock(type),
      ],
    })
  }

  return (
    <div className="visual-email-editor">
      <div className="visual-email-editor__toolbar">
        <span>Add block</span>

        <button
          className="button button--secondary"
          onClick={() => add('text')}
          type="button"
        >
          <Type size={13} />
          Text
        </button>

        <button
          className="button button--secondary"
          onClick={() => add('image')}
          type="button"
        >
          <ImageIcon size={13} />
          Image
        </button>

        <button
          className="button button--secondary"
          onClick={() => add('button')}
          type="button"
        >
          <MousePointerClick size={13} />
          Button
        </button>

        <button
          className="button button--secondary"
          onClick={() => add('columns')}
          type="button"
        >
          <Columns2 size={13} />
          Columns
        </button>
      </div>

      <div className="visual-email-editor__workspace">
        <div className="visual-email-editor__blocks">
          {document.blocks.map(
            (block, index) => (
              <article
                className={
                  draggedId === block.id
                    ? 'visual-email-block visual-email-block--dragging'
                    : 'visual-email-block'
                }
                draggable
                key={block.id}
                onDragEnd={() =>
                  setDraggedId(null)
                }
                onDragOver={(event) =>
                  event.preventDefault()
                }
                onDragStart={(event) => {
                  event.dataTransfer.effectAllowed =
                    'move'
                  event.dataTransfer.setData(
                    'text/plain',
                    block.id,
                  )
                  setDraggedId(block.id)
                }}
                onDrop={(event) => {
                  event.preventDefault()
                  dropBefore(block.id)
                }}
              >
                <header className="visual-email-block__header">
                  <div>
                    <GripVertical
                      aria-hidden="true"
                      size={15}
                    />
                    <strong>
                      {blockLabel(block)}
                    </strong>
                  </div>

                  <div className="visual-email-block__actions">
                    <button
                      aria-label={`Move ${blockLabel(block)} up`}
                      className="copy-button"
                      disabled={index === 0}
                      onClick={() =>
                        move(block.id, -1)
                      }
                      type="button"
                    >
                      <ArrowUp size={13} />
                    </button>

                    <button
                      aria-label={`Move ${blockLabel(block)} down`}
                      className="copy-button"
                      disabled={
                        index
                        === document.blocks.length - 1
                      }
                      onClick={() =>
                        move(block.id, 1)
                      }
                      type="button"
                    >
                      <ArrowDown size={13} />
                    </button>

                    <button
                      aria-label={`Remove ${blockLabel(block)}`}
                      className="copy-button"
                      disabled={
                        document.blocks.length === 1
                      }
                      onClick={() =>
                        remove(block.id)
                      }
                      type="button"
                    >
                      <Trash2 size={13} />
                    </button>
                  </div>
                </header>

                <div className="visual-email-block__body">
                  {block.type === 'text' && (
                    <>
                      <label className="field">
                        <span>Text</span>
                        <textarea
                          maxLength={10000}
                          onChange={(event) =>
                            replaceBlock(
                              block.id,
                              {
                                ...block,
                                text:
                                  event.target.value,
                              },
                            )
                          }
                          rows={5}
                          value={block.text}
                        />
                      </label>

                      <label className="field">
                        <span>Alignment</span>
                        <select
                          onChange={(event) =>
                            replaceBlock(
                              block.id,
                              {
                                ...block,
                                align:
                                  (event.target.value as ConsoleVisualEmailAlignment),
                              },
                            )
                          }
                          value={block.align}
                        >
                          {alignOptions()}
                        </select>
                      </label>
                    </>
                  )}

                  {block.type === 'image' && (
                    <>
                      <label className="field">
                        <span>HTTPS image URL</span>
                        <input
                          maxLength={2048}
                          onChange={(event) =>
                            replaceBlock(
                              block.id,
                              {
                                ...block,
                                url:
                                  event.target.value,
                              },
                            )
                          }
                          type="url"
                          value={block.url}
                        />
                      </label>

                      <label className="field">
                        <span>Alt text</span>
                        <input
                          maxLength={255}
                          onChange={(event) =>
                            replaceBlock(
                              block.id,
                              {
                                ...block,
                                alt:
                                  event.target.value,
                              },
                            )
                          }
                          value={block.alt}
                        />
                      </label>

                      <label className="field">
                        <span>Alignment</span>
                        <select
                          onChange={(event) =>
                            replaceBlock(
                              block.id,
                              {
                                ...block,
                                align:
                                  (event.target.value as ConsoleVisualEmailAlignment),
                              },
                            )
                          }
                          value={block.align}
                        >
                          {alignOptions()}
                        </select>
                      </label>
                    </>
                  )}

                  {block.type === 'button' && (
                    <>
                      <label className="field">
                        <span>Label</span>
                        <input
                          maxLength={200}
                          onChange={(event) =>
                            replaceBlock(
                              block.id,
                              {
                                ...block,
                                label:
                                  event.target.value,
                              },
                            )
                          }
                          value={block.label}
                        />
                      </label>

                      <label className="field">
                        <span>HTTPS destination</span>
                        <input
                          maxLength={2048}
                          onChange={(event) =>
                            replaceBlock(
                              block.id,
                              {
                                ...block,
                                url:
                                  event.target.value,
                              },
                            )
                          }
                          type="url"
                          value={block.url}
                        />
                      </label>

                      <label className="field">
                        <span>Alignment</span>
                        <select
                          onChange={(event) =>
                            replaceBlock(
                              block.id,
                              {
                                ...block,
                                align:
                                  (event.target.value as ConsoleVisualEmailAlignment),
                              },
                            )
                          }
                          value={block.align}
                        >
                          {alignOptions()}
                        </select>
                      </label>
                    </>
                  )}

                  {block.type === 'columns' && (
                    <div className="visual-email-columns-editor">
                      {block.columns.map(
                        (column, columnIndex) => (
                          <div
                            className="visual-email-columns-editor__column"
                            key={columnIndex}
                          >
                            <label className="field">
                              <span>
                                Column {columnIndex + 1}
                              </span>

                              <textarea
                                maxLength={10000}
                                onChange={(event) => {
                                  const columns =
                                    [
                                      ...block.columns,
                                    ] as typeof block.columns

                                  columns[columnIndex] = {
                                    ...column,
                                    text:
                                      event.target.value,
                                  }

                                  replaceBlock(
                                    block.id,
                                    {
                                      ...block,
                                      columns,
                                    },
                                  )
                                }}
                                rows={4}
                                value={column.text}
                              />
                            </label>

                            <label className="field">
                              <span>Alignment</span>
                              <select
                                onChange={(event) => {
                                  const columns =
                                    [
                                      ...block.columns,
                                    ] as typeof block.columns

                                  columns[columnIndex] = {
                                    ...column,
                                    align:
                                      (event.target.value as ConsoleVisualEmailAlignment),
                                  }

                                  replaceBlock(
                                    block.id,
                                    {
                                      ...block,
                                      columns,
                                    },
                                  )
                                }}
                                value={column.align}
                              >
                                {alignOptions()}
                              </select>
                            </label>
                          </div>
                        ),
                      )}
                    </div>
                  )}
                </div>
              </article>
            ),
          )}
        </div>

        <aside className="visual-email-canvas">
          <div className="visual-email-canvas__label">
            Live layout preview
          </div>

          <div className="visual-email-canvas__email">
            {document.blocks.map(
              (block) => (
                <div
                  className="visual-email-canvas__row"
                  key={block.id}
                  style={{
                    textAlign:
                      block.type === 'columns'
                        ? undefined
                        : block.align,
                  }}
                >
                  {block.type === 'text' && (
                    <p>{block.text}</p>
                  )}

                  {block.type === 'image' && (
                    <div className="visual-email-canvas__image">
                      <ImageIcon size={24} />
                      <strong>
                        {block.alt || 'Image'}
                      </strong>
                      <small>{block.url}</small>
                    </div>
                  )}

                  {block.type === 'button' && (
                    <span className="visual-email-canvas__button">
                      {block.label || 'Button'}
                    </span>
                  )}

                  {block.type === 'columns' && (
                    <div className="visual-email-canvas__columns">
                      {block.columns.map(
                        (column, columnIndex) => (
                          <p
                            key={columnIndex}
                            style={{
                              textAlign:
                                column.align,
                            }}
                          >
                            {column.text}
                          </p>
                        ),
                      )}
                    </div>
                  )}
                </div>
              ),
            )}
          </div>

          <p className="visual-email-canvas__privacy">
            Image URLs are not loaded in the editor.
            Final HTML is generated by the API.
          </p>
        </aside>
      </div>

      <div className="visual-email-editor__footer">
        <Plus size={13} />
        {document.blocks.length}
        {' / 100 blocks'}
      </div>
    </div>
  )
}
