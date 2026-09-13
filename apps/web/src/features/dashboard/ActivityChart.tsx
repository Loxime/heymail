import type {
  DashboardActivityDay,
} from '../../lib/api/types'
import {
  formatShortDate,
} from '../../lib/format/date'

interface ActivityChartProps {
  data: DashboardActivityDay[]
}

export function ActivityChart({
  data,
}: ActivityChartProps) {
  const max =
    Math.max(
      1,
      ...data.map(
        (day) =>
          Math.max(
            day.submitted,
            day.delivered,
            day.bounced,
          ),
      ),
    )

  return (
    <div className="activity-chart">
      <div className="activity-chart__legend">
        <span>
          <i className="legend-dot legend-dot--submitted" />
          Submitted
        </span>

        <span>
          <i className="legend-dot legend-dot--delivered" />
          Delivered
        </span>

        <span>
          <i className="legend-dot legend-dot--bounced" />
          Bounced
        </span>
      </div>

      <div className="activity-chart__plot">
        {data.map((day) => (
          <div
            className="activity-chart__day"
            key={day.date}
          >
            <div className="activity-chart__bars">
              <span
                className="activity-bar activity-bar--submitted"
                style={{
                  height:
                    `${Math.max(
                      3,
                      day.submitted / max * 100,
                    )}%`,
                }}
                title={`${day.submitted} submitted`}
              />

              <span
                className="activity-bar activity-bar--delivered"
                style={{
                  height:
                    `${Math.max(
                      3,
                      day.delivered / max * 100,
                    )}%`,
                }}
                title={`${day.delivered} delivered`}
              />

              <span
                className="activity-bar activity-bar--bounced"
                style={{
                  height:
                    `${Math.max(
                      3,
                      day.bounced / max * 100,
                    )}%`,
                }}
                title={`${day.bounced} bounced`}
              />
            </div>

            <span className="activity-chart__date">
              {formatShortDate(
                day.date,
              )}
            </span>
          </div>
        ))}
      </div>
    </div>
  )
}
