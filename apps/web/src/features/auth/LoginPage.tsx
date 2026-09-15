import {
  LockKeyhole,
  Mail,
} from 'lucide-react'
import {
  useMutation,
} from '@tanstack/react-query'
import {
  useState,
} from 'react'

import {
  apiPost,
} from '../../lib/api/client'
import type {
  ConsoleSessionResponse,
} from '../../lib/api/types'

export function LoginPage() {
  const [
    email,
    setEmail,
  ] = useState('')

  const [
    password,
    setPassword,
  ] = useState('')

  const login =
    useMutation({
      mutationFn: () =>
        apiPost<ConsoleSessionResponse>(
          '/console/auth/login',
          {
            email,
            password,
          },
        ),

      onSuccess: () => {
        window.location.assign('/')
      },
    })

  return (
    <main className="login-page">
      <section className="login-card">
        <div className="login-brand">
          <div className="login-brand__mark">
            <Mail size={22} />
          </div>

          <div>
            <strong>HeyMail</strong>
            <span>Transactional email</span>
          </div>
        </div>

        <div className="login-copy">
          <span className="eyebrow">
            Console sécurisée
          </span>

          <h1>Se connecter</h1>

          <p>
            Accédez à la console HeyMail,
            aux messages et aux outils de
            délivrabilité.
          </p>
        </div>

        <form
          className="login-form"
          onSubmit={(event) => {
            event.preventDefault()

            if (
              email.trim() !== ''
              && password !== ''
            ) {
              login.mutate()
            }
          }}
        >
          <label className="field">
            <span>Email</span>

            <input
              autoComplete="email"
              onChange={(event) =>
                setEmail(
                  event.target.value,
                )
              }
              placeholder="vous@exemple.fr"
              type="email"
              value={email}
            />
          </label>

          <label className="field">
            <span>Mot de passe</span>

            <div className="login-password">
              <LockKeyhole size={15} />

              <input
                autoComplete="current-password"
                onChange={(event) =>
                  setPassword(
                    event.target.value,
                  )
                }
                type="password"
                value={password}
              />
            </div>
          </label>

          {login.error instanceof Error && (
            <div className="inline-error">
              {login.error.message}
            </div>
          )}

          <button
            className="button button--primary login-submit"
            disabled={
              login.isPending
              || email.trim() === ''
              || password === ''
            }
            type="submit"
          >
            {login.isPending
              ? 'Connexion…'
              : 'Se connecter'}
          </button>
        </form>
      </section>
    </main>
  )
}
