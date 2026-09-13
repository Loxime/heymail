const dateTimeFormatter =
  new Intl.DateTimeFormat(
    undefined,
    {
      dateStyle: 'medium',
      timeStyle: 'short',
    },
  )

const shortDateFormatter =
  new Intl.DateTimeFormat(
    undefined,
    {
      month: 'short',
      day: 'numeric',
    },
  )

export function formatDateTime(
  value: string,
): string {
  return dateTimeFormatter.format(
    new Date(value),
  )
}

export function formatShortDate(
  value: string,
): string {
  return shortDateFormatter.format(
    new Date(
      `${value}T00:00:00Z`,
    ),
  )
}

export function formatPercent(
  value: number,
): string {
  return new Intl.NumberFormat(
    undefined,
    {
      style: 'percent',
      maximumFractionDigits: 1,
    },
  ).format(value)
}
