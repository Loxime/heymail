interface StatusBadgeProps {
  status: string
}

function labelForStatus(
  status: string,
): string {
  return status
    .split('_')
    .map(
      (part) =>
        part.charAt(0).toUpperCase()
        + part.slice(1),
    )
    .join(' ')
}

export function StatusBadge({
  status,
}: StatusBadgeProps) {
  return (
    <span
      className={`status-badge status-badge--${status}`}
    >
      <span
        className="status-badge__dot"
      />

      {labelForStatus(status)}
    </span>
  )
}
