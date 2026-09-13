import type {
  LucideIcon,
} from 'lucide-react'

interface KpiCardProps {
  label: string
  value: string
  detail: string
  icon: LucideIcon
  tone?: 'neutral' | 'success' | 'warning' | 'danger'
}

export function KpiCard({
  label,
  value,
  detail,
  icon: Icon,
  tone = 'neutral',
}: KpiCardProps) {
  return (
    <article
      className={`kpi-card kpi-card--${tone}`}
    >
      <div className="kpi-card__header">
        <span className="kpi-card__label">
          {label}
        </span>

        <span className="kpi-card__icon">
          <Icon size={18} />
        </span>
      </div>

      <strong className="kpi-card__value">
        {value}
      </strong>

      <span className="kpi-card__detail">
        {detail}
      </span>
    </article>
  )
}
