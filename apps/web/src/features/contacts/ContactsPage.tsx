import {
  Download,
  ListPlus,
  Plus,
  Save,
  Search,
  Send,
  Tags,
  Trash2,
  Upload,
  Users,
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
  apiDelete,
  apiGet,
  apiPatch,
  apiPost,
  apiPostText,
} from '../../lib/api/client'
import type {
  ConsoleContact,
  ConsoleContactImportResponse,
  ConsoleContactListResponse,
  ConsoleContactListListResponse,
  ConsoleContactListResponseItem,
  ConsoleContactTagListResponse,
} from '../../lib/api/types'

type CustomFieldValue =
  | string
  | number
  | boolean
  | null

function parseTags(
  raw: string,
): string[] {
  return Array.from(
    new Map(
      raw
        .split(',')
        .map((value) => value.trim())
        .filter(Boolean)
        .map((value) => [
          value.toLowerCase(),
          value,
        ]),
    ).values(),
  )
}

function parseCustomFields(
  raw: string,
): Record<string, CustomFieldValue> {
  const parsed: unknown =
    JSON.parse(
      raw.trim() === ''
        ? '{}'
        : raw,
    )

  if (
    parsed === null
    || Array.isArray(parsed)
    || typeof parsed !== 'object'
  ) {
    throw new Error(
      'Custom fields must be a JSON object.',
    )
  }

  return parsed as Record<
    string,
    CustomFieldValue
  >
}

function listNames(
  ids: number[],
  lists: ConsoleContactListResponseItem[],
): string {
  const byId =
    new Map(
      lists.map(
        (list) => [
          list.id,
          list.name,
        ],
      ),
    )

  return ids
    .map(
      (id) =>
        byId.get(id)
        ?? `#${id}`,
    )
    .join(', ')
}

export function ContactsPage() {
  const queryClient =
    useQueryClient()

  const [search, setSearch] =
    useState('')
  const [tagFilter, setTagFilter] =
    useState('')
  const [listFilter, setListFilter] =
    useState('')

  const [newEmail, setNewEmail] =
    useState('')
  const [newName, setNewName] =
    useState('')
  const [newTags, setNewTags] =
    useState('')
  const [newListIds, setNewListIds] =
    useState<number[]>([])
  const [
    newCustomFields,
    setNewCustomFields,
  ] = useState('{}')

  const [newListName, setNewListName] =
    useState('')

  const [selectedId, setSelectedId] =
    useState<number | null>(null)
  const [editEmail, setEditEmail] =
    useState('')
  const [editName, setEditName] =
    useState('')
  const [editTags, setEditTags] =
    useState('')
  const [editListIds, setEditListIds] =
    useState<number[]>([])
  const [
    editCustomFields,
    setEditCustomFields,
  ] = useState('{}')

  const [
    importFile,
    setImportFile,
  ] = useState<File | null>(null)
  const [
    importResult,
    setImportResult,
  ] = useState<ConsoleContactImportResponse | null>(
    null,
  )
  const [error, setError] =
    useState<string | null>(null)

  const segmentQuery =
    useMemo(
      () => {
        const params =
          new URLSearchParams()

        params.set(
          'limit',
          '100',
        )

        if (search.trim() !== '') {
          params.set(
            'q',
            search.trim(),
          )
        }

        if (tagFilter !== '') {
          params.set(
            'tag',
            tagFilter,
          )
        }

        if (listFilter !== '') {
          params.set(
            'list',
            listFilter,
          )
        }

        return params.toString()
      },
      [
        listFilter,
        search,
        tagFilter,
      ],
    )

  const exportQuery =
    useMemo(
      () => {
        const params =
          new URLSearchParams()

        if (search.trim() !== '') {
          params.set(
            'q',
            search.trim(),
          )
        }

        if (tagFilter !== '') {
          params.set(
            'tag',
            tagFilter,
          )
        }

        if (listFilter !== '') {
          params.set(
            'list',
            listFilter,
          )
        }

        const query =
          params.toString()

        return query === ''
          ? '/console/contacts/export'
          : `/console/contacts/export?${query}`
      },
      [
        listFilter,
        search,
        tagFilter,
      ],
    )

  const contacts =
    useQuery({
      queryKey: [
        'console-contacts',
        segmentQuery,
      ],
      queryFn: () =>
        apiGet<ConsoleContactListResponse>(
          `/console/contacts?${segmentQuery}`,
        ),
    })

  const lists =
    useQuery({
      queryKey: [
        'console-contact-lists',
      ],
      queryFn: () =>
        apiGet<ConsoleContactListListResponse>(
          '/console/contact-lists',
        ),
    })

  const tags =
    useQuery({
      queryKey: [
        'console-contact-tags',
      ],
      queryFn: () =>
        apiGet<ConsoleContactTagListResponse>(
          '/console/contact-tags',
        ),
    })

  const items =
    contacts.data?.items
    ?? []

  const selected =
    useMemo(
      () =>
        items.find(
          (contact) =>
            contact.id === selectedId,
        )
        ?? null,
      [
        items,
        selectedId,
      ],
    )

  useEffect(
    () => {
      if (!selected) {
        return
      }

      setEditEmail(
        selected.email,
      )
      setEditName(
        selected.name
        ?? '',
      )
      setEditTags(
        selected.tags.join(', '),
      )
      setEditListIds(
        selected.listIds,
      )
      setEditCustomFields(
        JSON.stringify(
          selected.customFields,
          null,
          2,
        ),
      )
    },
    [
      selected,
    ],
  )

  const invalidateContacts =
    async () => {
      await Promise.all([
        queryClient.invalidateQueries({
          queryKey: [
            'console-contacts',
          ],
        }),
        queryClient.invalidateQueries({
          queryKey: [
            'console-contact-lists',
          ],
        }),
        queryClient.invalidateQueries({
          queryKey: [
            'console-contact-tags',
          ],
        }),
      ])
    }

  const createContact =
    useMutation({
      mutationFn: () =>
        apiPost<ConsoleContact>(
          '/console/contacts',
          {
            email:
              newEmail.trim(),
            name:
              newName.trim() === ''
                ? null
                : newName.trim(),
            tags:
              parseTags(
                newTags,
              ),
            listIds:
              newListIds,
            customFields:
              parseCustomFields(
                newCustomFields,
              ),
          },
        ),
      onSuccess:
        async (created) => {
          setNewEmail('')
          setNewName('')
          setNewTags('')
          setNewListIds([])
          setNewCustomFields('{}')
          setSelectedId(
            created.id,
          )
          setError(null)
          await invalidateContacts()
        },
      onError:
        (caught) =>
          setError(
            caught instanceof Error
              ? caught.message
              : 'Unable to create contact.',
          ),
    })

  const updateContact =
    useMutation({
      mutationFn: () => {
        if (!selected) {
          throw new Error(
            'Select a contact first.',
          )
        }

        return apiPatch<ConsoleContact>(
          `/console/contacts/${selected.id}`,
          {
            email:
              editEmail.trim(),
            name:
              editName.trim() === ''
                ? null
                : editName.trim(),
            tags:
              parseTags(
                editTags,
              ),
            listIds:
              editListIds,
            customFields:
              parseCustomFields(
                editCustomFields,
              ),
          },
        )
      },
      onSuccess:
        async () => {
          setError(null)
          await invalidateContacts()
        },
      onError:
        (caught) =>
          setError(
            caught instanceof Error
              ? caught.message
              : 'Unable to update contact.',
          ),
    })

  const deleteContact =
    useMutation({
      mutationFn: (id: number) =>
        apiDelete<void>(
          `/console/contacts/${id}`,
        ),
      onSuccess:
        async () => {
          setSelectedId(null)
          setError(null)
          await invalidateContacts()
        },
      onError:
        (caught) =>
          setError(
            caught instanceof Error
              ? caught.message
              : 'Unable to delete contact.',
          ),
    })

  const createList =
    useMutation({
      mutationFn: () =>
        apiPost<ConsoleContactListResponseItem>(
          '/console/contact-lists',
          {
            name:
              newListName.trim(),
          },
        ),
      onSuccess:
        async () => {
          setNewListName('')
          setError(null)
          await invalidateContacts()
        },
      onError:
        (caught) =>
          setError(
            caught instanceof Error
              ? caught.message
              : 'Unable to create list.',
          ),
    })

  const deleteList =
    useMutation({
      mutationFn: (id: number) =>
        apiDelete<void>(
          `/console/contact-lists/${id}`,
        ),
      onSuccess:
        async () => {
          setListFilter('')
          setError(null)
          await invalidateContacts()
        },
      onError:
        (caught) =>
          setError(
            caught instanceof Error
              ? caught.message
              : 'Unable to delete list.',
          ),
    })

  const importContacts =
    useMutation({
      mutationFn:
        async () => {
          if (!importFile) {
            throw new Error(
              'Choose a CSV file first.',
            )
          }

          if (
            importFile.size === 0
            || importFile.size > 2_000_000
          ) {
            throw new Error(
              'CSV file must contain between 1 byte and 2 MB.',
            )
          }

          return apiPostText<ConsoleContactImportResponse>(
            '/console/contacts/import',
            await importFile.text(),
            'text/csv',
          )
        },
      onSuccess:
        async (result) => {
          setImportResult(
            result,
          )
          setImportFile(null)
          setError(null)
          await invalidateContacts()
        },
      onError:
        (caught) =>
          setError(
            caught instanceof Error
              ? caught.message
              : 'Unable to import contacts.',
          ),
    })

  const toggleList = (
    id: number,
    selectedIds: number[],
    setSelectedIds:
      (value: number[]) => void,
  ) => {
    setSelectedIds(
      selectedIds.includes(id)
        ? selectedIds.filter(
            (value) =>
              value !== id,
          )
        : [
            ...selectedIds,
            id,
          ],
    )
  }

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Audience
          </span>

          <h1>Contacts</h1>

          <p>
            Workspace contacts, lists,
            tags, custom fields and CSV
            segmentation.
          </p>
        </div>

        <a
          className="button button--secondary"
          download="heymail-contacts.csv"
          href={exportQuery}
        >
          <Download size={14} />
          Export segment
        </a>
      </header>

      {error && (
        <div className="inline-error contacts-error">
          {error}
        </div>
      )}

      <section className="panel contacts-segment">
        <header className="panel__header">
          <div>
            <h2>
              Segment contacts
            </h2>

            <p>
              Search, tag and list filters
              are intersected.
            </p>
          </div>
        </header>

        <div className="contacts-segment__filters">
          <label className="field contacts-search">
            <span>
              Search
            </span>

            <div className="contacts-search__input">
              <Search size={14} />

              <input
                onChange={(event) =>
                  setSearch(
                    event.target.value,
                  )
                }
                placeholder="Email or name"
                value={search}
              />
            </div>
          </label>

          <label className="field">
            <span>
              Tag
            </span>

            <select
              onChange={(event) =>
                setTagFilter(
                  event.target.value,
                )
              }
              value={tagFilter}
            >
              <option value="">
                All tags
              </option>

              {tags.data?.items.map(
                (tag) => (
                  <option
                    key={tag.id}
                    value={tag.name}
                  >
                    {tag.name}
                    {' '}
                    ({tag.contactCount})
                  </option>
                ),
              )}
            </select>
          </label>

          <label className="field">
            <span>
              List
            </span>

            <select
              onChange={(event) =>
                setListFilter(
                  event.target.value,
                )
              }
              value={listFilter}
            >
              <option value="">
                All lists
              </option>

              {lists.data?.items.map(
                (list) => (
                  <option
                    key={list.id}
                    value={list.id}
                  >
                    {list.name}
                    {' '}
                    ({list.contactCount})
                  </option>
                ),
              )}
            </select>
          </label>
        </div>
      </section>

      <div className="contacts-grid">
        <section className="panel contacts-table-panel">
          <header className="panel__header">
            <div>
              <h2>
                <Users size={15} />
                Contacts
              </h2>

              <p>
                {items.length}
                {' '}
                matching contacts shown
                (max 100).
              </p>
            </div>
          </header>

          <div className="contacts-table">
            {contacts.isLoading && (
              <div className="template-empty">
                Loading contacts…
              </div>
            )}

            {!contacts.isLoading
              && items.length === 0 && (
                <div className="template-empty">
                  No contacts match this segment.
                </div>
              )}

            {items.map(
              (contact) => (
                <button
                  className={
                    contact.id === selectedId
                      ? 'contact-row contact-row--active'
                      : 'contact-row'
                  }
                  key={contact.id}
                  onClick={() =>
                    setSelectedId(
                      contact.id,
                    )
                  }
                  type="button"
                >
                  <div>
                    <strong>
                      {contact.name
                      ?? contact.email}
                    </strong>

                    {contact.name && (
                      <span>
                        {contact.email}
                      </span>
                    )}
                  </div>

                  <div className="contact-row__meta">
                    {contact.tags.map(
                      (tag) => (
                        <span
                          className="contact-chip"
                          key={tag}
                        >
                          {tag}
                        </span>
                      ),
                    )}

                    {contact.listIds.length > 0 && (
                      <span className="contact-list-copy">
                        {
                          listNames(
                            contact.listIds,
                            lists.data?.items
                            ?? [],
                          )
                        }
                      </span>
                    )}
                  </div>
                </button>
              ),
            )}
          </div>
        </section>

        <section className="panel contact-editor">
          <header className="panel__header">
            <div>
              <h2>
                {selected
                  ? 'Edit contact'
                  : 'New contact'}
              </h2>

              <p>
                {
                  selected
                    ? 'Update this workspace contact.'
                    : 'Create a workspace contact.'
                }
              </p>
            </div>
          </header>

          {selected
            ? (
                <div className="contact-editor__body">
                  <div className="send-form__two">
                    <label className="field">
                      <span>Email</span>

                      <input
                        onChange={(event) =>
                          setEditEmail(
                            event.target.value,
                          )
                        }
                        type="email"
                        value={editEmail}
                      />
                    </label>

                    <label className="field">
                      <span>Name</span>

                      <input
                        maxLength={160}
                        onChange={(event) =>
                          setEditName(
                            event.target.value,
                          )
                        }
                        value={editName}
                      />
                    </label>
                  </div>

                  <label className="field">
                    <span>
                      Tags
                    </span>

                    <input
                      onChange={(event) =>
                        setEditTags(
                          event.target.value,
                        )
                      }
                      placeholder="customer, vip"
                      value={editTags}
                    />
                  </label>

                  <ContactListChoices
                    lists={
                      lists.data?.items
                      ?? []
                    }
                    selected={
                      editListIds
                    }
                    toggle={(id) =>
                      toggleList(
                        id,
                        editListIds,
                        setEditListIds,
                      )
                    }
                  />

                  <label className="field">
                    <span>
                      Custom fields JSON
                    </span>

                    <textarea
                      onChange={(event) =>
                        setEditCustomFields(
                          event.target.value,
                        )
                      }
                      rows={8}
                      value={editCustomFields}
                    />
                  </label>

                  <div className="contact-editor__actions">
                    <Link
                      className="button button--secondary"
                      to={
                        `/send?contact=${selected.id}`
                      }
                    >
                      <Send size={13} />
                      Send email
                    </Link>

                    <button
                      className="button button--secondary"
                      disabled={
                        deleteContact.isPending
                      }
                      onClick={() =>
                        deleteContact.mutate(
                          selected.id,
                        )
                      }
                      type="button"
                    >
                      <Trash2 size={13} />
                      Delete
                    </button>

                    <button
                      className="button button--primary"
                      disabled={
                        updateContact.isPending
                        || editEmail.trim() === ''
                      }
                      onClick={() =>
                        updateContact.mutate()
                      }
                      type="button"
                    >
                      <Save size={13} />
                      Save contact
                    </button>
                  </div>
                </div>
              )
            : (
                <div className="contact-editor__body">
                  <div className="send-form__two">
                    <label className="field">
                      <span>Email</span>

                      <input
                        onChange={(event) =>
                          setNewEmail(
                            event.target.value,
                          )
                        }
                        placeholder="ada@example.com"
                        type="email"
                        value={newEmail}
                      />
                    </label>

                    <label className="field">
                      <span>Name</span>

                      <input
                        maxLength={160}
                        onChange={(event) =>
                          setNewName(
                            event.target.value,
                          )
                        }
                        placeholder="Ada Lovelace"
                        value={newName}
                      />
                    </label>
                  </div>

                  <label className="field">
                    <span>
                      Tags
                    </span>

                    <input
                      onChange={(event) =>
                        setNewTags(
                          event.target.value,
                        )
                      }
                      placeholder="customer, vip"
                      value={newTags}
                    />
                  </label>

                  <ContactListChoices
                    lists={
                      lists.data?.items
                      ?? []
                    }
                    selected={
                      newListIds
                    }
                    toggle={(id) =>
                      toggleList(
                        id,
                        newListIds,
                        setNewListIds,
                      )
                    }
                  />

                  <label className="field">
                    <span>
                      Custom fields JSON
                    </span>

                    <textarea
                      onChange={(event) =>
                        setNewCustomFields(
                          event.target.value,
                        )
                      }
                      rows={8}
                      value={newCustomFields}
                    />
                  </label>

                  <button
                    className="button button--primary contact-create"
                    disabled={
                      createContact.isPending
                      || newEmail.trim() === ''
                    }
                    onClick={() =>
                      createContact.mutate()
                    }
                    type="button"
                  >
                    <Plus size={13} />
                    Create contact
                  </button>
                </div>
              )}
        </section>
      </div>

      <div className="contacts-tools">
        <section className="panel">
          <header className="panel__header">
            <div>
              <h2>
                <ListPlus size={15} />
                Lists
              </h2>

              <p>
                Reusable contact groups.
              </p>
            </div>
          </header>

          <div className="contacts-tool__body">
            <div className="contacts-inline-form">
              <input
                maxLength={120}
                onChange={(event) =>
                  setNewListName(
                    event.target.value,
                  )
                }
                placeholder="Customers"
                value={newListName}
              />

              <button
                className="button button--primary"
                disabled={
                  createList.isPending
                  || newListName.trim() === ''
                }
                onClick={() =>
                  createList.mutate()
                }
                type="button"
              >
                <Plus size={13} />
                Add list
              </button>
            </div>

            <div className="contact-list-manager">
              {lists.data?.items.map(
                (list) => (
                  <div
                    className="contact-list-manager__row"
                    key={list.id}
                  >
                    <div>
                      <strong>
                        {list.name}
                      </strong>

                      <span>
                        {list.contactCount}
                        {' '}
                        contacts
                      </span>
                    </div>

                    <button
                      aria-label={
                        `Delete ${list.name}`
                      }
                      className="recipient-remove"
                      disabled={
                        deleteList.isPending
                      }
                      onClick={() =>
                        deleteList.mutate(
                          list.id,
                        )
                      }
                      type="button"
                    >
                      <Trash2 size={13} />
                    </button>
                  </div>
                ),
              )}
            </div>
          </div>
        </section>

        <section className="panel">
          <header className="panel__header">
            <div>
              <h2>
                <Tags size={15} />
                Tags
              </h2>

              <p>
                Created automatically from
                contact tags.
              </p>
            </div>
          </header>

          <div className="contacts-tool__body contact-tag-cloud">
            {tags.data?.items.length === 0 && (
              <span className="table-muted">
                No tags yet.
              </span>
            )}

            {tags.data?.items.map(
              (tag) => (
                <button
                  className="contact-chip contact-chip--button"
                  key={tag.id}
                  onClick={() =>
                    setTagFilter(
                      tag.name,
                    )
                  }
                  type="button"
                >
                  {tag.name}
                  {' · '}
                  {tag.contactCount}
                </button>
              ),
            )}
          </div>
        </section>

        <section className="panel">
          <header className="panel__header">
            <div>
              <h2>
                <Upload size={15} />
                CSV import
              </h2>

              <p>
                Atomic import, maximum
                500 contacts / 2 MB.
              </p>
            </div>
          </header>

          <div className="contacts-tool__body">
            <code className="contacts-csv-format">
              email,name,tags_json,lists_json,custom_fields_json
            </code>

            <input
              accept=".csv,text/csv"
              onChange={(event) =>
                setImportFile(
                  event.target.files?.[0]
                  ?? null,
                )
              }
              type="file"
            />

            <button
              className="button button--primary"
              disabled={
                importContacts.isPending
                || importFile === null
              }
              onClick={() =>
                importContacts.mutate()
              }
              type="button"
            >
              <Upload size={13} />
              Import CSV
            </button>

            {importResult && (
              <div className="send-success">
                <div>
                  <strong>
                    Import complete
                  </strong>

                  <span>
                    {importResult.rows}
                    {' rows · '}
                    {importResult.created}
                    {' created · '}
                    {importResult.updated}
                    {' updated'}
                  </span>
                </div>
              </div>
            )}
          </div>
        </section>
      </div>
    </div>
  )
}

function ContactListChoices({
  lists,
  selected,
  toggle,
}: {
  lists: ConsoleContactListResponseItem[]
  selected: number[]
  toggle: (id: number) => void
}) {
  return (
    <fieldset className="contact-list-choices">
      <legend>
        Lists
      </legend>

      {lists.length === 0 && (
        <span className="table-muted">
          No lists yet.
        </span>
      )}

      {lists.map(
        (list) => (
          <label key={list.id}>
            <input
              checked={
                selected.includes(
                  list.id,
                )
              }
              onChange={() =>
                toggle(
                  list.id,
                )
              }
              type="checkbox"
            />

            <span>
              {list.name}
            </span>
          </label>
        ),
      )}
    </fieldset>
  )
}
