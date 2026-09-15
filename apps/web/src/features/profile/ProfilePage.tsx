import {
  Heart,
  KeyRound,
  LogOut,
  Mail,
  Save,
  Trash2,
  UserRound,
} from 'lucide-react'
import {
  useMutation,
  useQuery,
  useQueryClient,
} from '@tanstack/react-query'
import {
  useEffect,
  useState,
} from 'react'

import {
  apiDelete,
  apiGet,
  apiPatch,
  apiPost,
} from '../../lib/api/client'
import type {
  ConsoleProfileResponse,
} from '../../lib/api/types'

export function ProfilePage() {
  const queryClient = useQueryClient()

  const profile = useQuery({
    queryKey: [
      'console-profile',
    ],
    queryFn: () =>
      apiGet<ConsoleProfileResponse>(
        '/console/profile',
      ),
  })

  const [firstName, setFirstName] =
    useState('')
  const [lastName, setLastName] =
    useState('')
  const [email, setEmail] =
    useState('')

  const [currentPassword, setCurrentPassword] =
    useState('')
  const [newPassword, setNewPassword] =
    useState('')

  const [favoriteEmail, setFavoriteEmail] =
    useState('')
  const [favoriteName, setFavoriteName] =
    useState('')

  const [deletePassword, setDeletePassword] =
    useState('')
  const [deleteConfirm, setDeleteConfirm] =
    useState('')

  useEffect(
    () => {
      if (!profile.data) {
        return
      }

      setFirstName(
        profile.data.user.firstName,
      )
      setLastName(
        profile.data.user.lastName,
      )
      setEmail(
        profile.data.user.email,
      )
    },
    [
      profile.data,
    ],
  )

  const updateProfile = useMutation({
    mutationFn: () =>
      apiPatch<ConsoleProfileResponse>(
        '/console/profile',
        {
          firstName,
          lastName,
          email,
        },
      ),
    onSuccess: async () => {
      await queryClient.invalidateQueries({
        queryKey: [
          'console-profile',
        ],
      })
      await queryClient.invalidateQueries({
        queryKey: [
          'console-session',
        ],
      })
    },
  })

  const updatePassword = useMutation({
    mutationFn: () =>
      apiPost<{ updated: boolean }>(
        '/console/profile/password',
        {
          currentPassword,
          newPassword,
        },
      ),
    onSuccess: () => {
      setCurrentPassword('')
      setNewPassword('')
    },
  })

  const addFavorite = useMutation({
    mutationFn: () =>
      apiPost<ConsoleProfileResponse['favorites']>(
        '/console/profile/favorites',
        {
          email: favoriteEmail,
          name:
            favoriteName.trim() === ''
              ? null
              : favoriteName.trim(),
        },
      ),
    onSuccess: async () => {
      setFavoriteEmail('')
      setFavoriteName('')
      await queryClient.invalidateQueries({
        queryKey: [
          'console-profile',
        ],
      })
    },
  })

  const removeFavorite = useMutation({
    mutationFn: (id: number) =>
      apiDelete<void>(
        `/console/profile/favorites/${id}`,
      ),
    onSuccess: async () => {
      await queryClient.invalidateQueries({
        queryKey: [
          'console-profile',
        ],
      })
    },
  })

  const logout = useMutation({
    mutationFn: () =>
      apiPost<void>(
        '/console/auth/logout',
      ),
    onSettled: () => {
      window.location.assign('/login')
    },
  })

  const deleteAccount = useMutation({
    mutationFn: () =>
      apiDelete<void>(
        '/console/profile',
        {
          password: deletePassword,
          confirm: deleteConfirm,
        },
      ),
    onSuccess: () => {
      window.location.assign('/login')
    },
  })

  if (profile.isLoading) {
    return (
      <div className="page">
        <div className="skeleton skeleton--heading" />
        <div className="skeleton skeleton--panel" />
      </div>
    )
  }

  if (!profile.data) {
    return (
      <div className="state-card">
        <strong>Profil indisponible</strong>
      </div>
    )
  }

  const data = profile.data

  return (
    <div className="page">
      <header className="page-heading">
        <div>
          <span className="eyebrow">
            Compte
          </span>

          <h1>Profil</h1>

          <p>
            Gérez votre identité, vos
            contacts favoris et la sécurité
            de votre compte.
          </p>
        </div>

        <button
          className="button button--secondary"
          onClick={() => logout.mutate()}
          type="button"
        >
          <LogOut size={14} />
          Déconnexion
        </button>
      </header>

      <section className="profile-stats">
        <ProfileStat
          icon={Mail}
          label="Messages envoyés"
          value={data.stats.messagesSent}
        />

        <ProfileStat
          icon={Mail}
          label="Messages reçus"
          muted={!data.stats.messagesReceivedAvailable}
          value={
            data.stats.messagesReceivedAvailable
              ? data.stats.messagesReceived
              : 'Bientôt'
          }
        />

        <ProfileStat
          icon={Heart}
          label="Contacts favoris"
          value={data.stats.favoriteContacts}
        />
      </section>

      <div className="profile-grid">
        <section className="panel profile-panel">
          <header className="panel__header">
            <h2>Informations personnelles</h2>
            <p>
              Nom, prénom et email de connexion.
            </p>
          </header>

          <div className="profile-panel__body">
            <div className="profile-avatar">
              <UserRound size={24} />
            </div>

            <div className="profile-form-grid">
              <label className="field">
                <span>Prénom</span>
                <input
                  onChange={(event) =>
                    setFirstName(event.target.value)
                  }
                  value={firstName}
                />
              </label>

              <label className="field">
                <span>Nom</span>
                <input
                  onChange={(event) =>
                    setLastName(event.target.value)
                  }
                  value={lastName}
                />
              </label>

              <label className="field profile-form-grid__wide">
                <span>Email</span>
                <input
                  onChange={(event) =>
                    setEmail(event.target.value)
                  }
                  type="email"
                  value={email}
                />
              </label>
            </div>

            {updateProfile.error instanceof Error && (
              <div className="inline-error">
                {updateProfile.error.message}
              </div>
            )}

            <button
              className="button button--primary button--inline"
              disabled={updateProfile.isPending}
              onClick={() => updateProfile.mutate()}
              type="button"
            >
              <Save size={14} />
              Enregistrer
            </button>
          </div>
        </section>

        <section className="panel profile-panel">
          <header className="panel__header">
            <h2>Sécurité</h2>
            <p>
              Changez votre mot de passe.
            </p>
          </header>

          <div className="profile-panel__body">
            <label className="field">
              <span>Mot de passe actuel</span>
              <input
                onChange={(event) =>
                  setCurrentPassword(event.target.value)
                }
                type="password"
                value={currentPassword}
              />
            </label>

            <label className="field">
              <span>Nouveau mot de passe</span>
              <input
                minLength={12}
                onChange={(event) =>
                  setNewPassword(event.target.value)
                }
                type="password"
                value={newPassword}
              />
            </label>

            {updatePassword.error instanceof Error && (
              <div className="inline-error">
                {updatePassword.error.message}
              </div>
            )}

            <button
              className="button button--secondary"
              disabled={
                updatePassword.isPending
                || currentPassword === ''
                || newPassword.length < 12
              }
              onClick={() => updatePassword.mutate()}
              type="button"
            >
              <KeyRound size={14} />
              Modifier le mot de passe
            </button>
          </div>
        </section>
      </div>

      <section className="panel profile-panel">
        <header className="panel__header">
          <h2>Contacts favoris</h2>
          <p>
            Destinataires réutilisables depuis
            vos futurs écrans d'envoi.
          </p>
        </header>

        <div className="profile-panel__body">
          <div className="favorite-form">
            <input
              onChange={(event) =>
                setFavoriteEmail(event.target.value)
              }
              placeholder="contact@exemple.fr"
              type="email"
              value={favoriteEmail}
            />

            <input
              onChange={(event) =>
                setFavoriteName(event.target.value)
              }
              placeholder="Nom (optionnel)"
              value={favoriteName}
            />

            <button
              className="button button--primary button--inline"
              disabled={
                addFavorite.isPending
                || favoriteEmail.trim() === ''
              }
              onClick={() => addFavorite.mutate()}
              type="button"
            >
              Ajouter
            </button>
          </div>

          <div className="favorite-list">
            {data.favorites.length === 0 && (
              <span className="table-muted">
                Aucun contact favori.
              </span>
            )}

            {data.favorites.map((favorite) => (
              <div
                className="favorite-row"
                key={favorite.id}
              >
                <div>
                  <strong>
                    {favorite.name ?? favorite.email}
                  </strong>
                  {favorite.name && (
                    <span>{favorite.email}</span>
                  )}
                </div>

                <button
                  aria-label="Supprimer le contact favori"
                  className="recipient-remove"
                  onClick={() =>
                    removeFavorite.mutate(favorite.id)
                  }
                  type="button"
                >
                  <Trash2 size={14} />
                </button>
              </div>
            ))}
          </div>
        </div>
      </section>

      <section className="panel danger-zone">
        <header className="panel__header">
          <h2>Zone dangereuse</h2>
          <p>
            La suppression du compte est définitive.
          </p>
        </header>

        <div className="profile-panel__body">
          <div className="favorite-form">
            <input
              onChange={(event) =>
                setDeletePassword(event.target.value)
              }
              placeholder="Mot de passe"
              type="password"
              value={deletePassword}
            />

            <input
              onChange={(event) =>
                setDeleteConfirm(event.target.value)
              }
              placeholder="Tapez DELETE"
              value={deleteConfirm}
            />

            <button
              className="button button--danger"
              disabled={
                deleteAccount.isPending
                || deletePassword === ''
                || deleteConfirm !== 'DELETE'
              }
              onClick={() => deleteAccount.mutate()}
              type="button"
            >
              <Trash2 size={14} />
              Supprimer mon compte
            </button>
          </div>

          {deleteAccount.error instanceof Error && (
            <div className="inline-error">
              {deleteAccount.error.message}
            </div>
          )}
        </div>
      </section>
    </div>
  )
}

interface ProfileStatProps {
  icon: typeof Mail
  label: string
  value: number | string
  muted?: boolean
}

function ProfileStat({
  icon: Icon,
  label,
  value,
  muted = false,
}: ProfileStatProps) {
  return (
    <div className={
      muted
        ? 'profile-stat profile-stat--muted'
        : 'profile-stat'
    }>
      <div className="profile-stat__icon">
        <Icon size={17} />
      </div>

      <div>
        <span>{label}</span>
        <strong>{value}</strong>
      </div>
    </div>
  )
}
