import {
  AlertTriangle,
  ArrowLeft,
} from 'lucide-react'
import {
  Link,
} from 'react-router-dom'

export function NotFoundPage() {
  return (
    <div className="page">
      <div className="not-found">
        <div className="not-found__icon">
          <AlertTriangle size={22} />
        </div>

        <span className="eyebrow">
          Error 404
        </span>

        <h1>
          Page not found
        </h1>

        <p>
          The requested HeyMail console
          page does not exist.
        </p>

        <Link
          className="button button--primary button--inline"
          to="/"
        >
          <ArrowLeft size={14} />
          Back to dashboard
        </Link>
      </div>
    </div>
  )
}
