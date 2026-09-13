export interface DashboardPeriod {
  from: string
  to: string
}

export interface DashboardMessages {
  total: number
  queued: number
  readyForSubmission: number
  submitting: number
  submissionUncertain: number
  submitted: number
}

export interface DashboardDelivery {
  delivered: number
  tempfail: number
  bounced: number
  terminalOutcomes: number
  deliveryRate: number
  bounceRate: number
}

export interface DashboardActivityDay {
  date: string
  submitted: number
  tempfail: number
  delivered: number
  bounced: number
}

export interface DashboardResponse {
  period: DashboardPeriod
  messages: DashboardMessages
  delivery: DashboardDelivery
  activity: DashboardActivityDay[]
}

export interface DeliverySummary {
  delivered: number
  tempfail: number
  bounced: number
}

export interface MessageListItem {
  messageId: number
  status: string
  createdAt: string
  readyForSubmissionAt: string | null
  submittingAt: string | null
  submissionUncertainAt: string | null
  submittedAt: string | null
  deliverySummary: DeliverySummary
}

export interface MessageListResponse {
  items: MessageListItem[]
  nextCursor: string | null
}

export interface MessageEvent {
  type: string
  occurredAt: string
  recipientHash: string | null
  smtpStatus: string | null
  detail: string | null
}

export interface MessageDetailResponse {
  messageId: number
  status: string
  createdAt: string
  readyForSubmissionAt: string | null
  submittingAt: string | null
  submissionUncertainAt: string | null
  submittedAt: string | null
  deliverySummary: DeliverySummary
  events: MessageEvent[]
}
